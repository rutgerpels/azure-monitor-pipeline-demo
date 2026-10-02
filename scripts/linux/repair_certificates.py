#!/usr/bin/env python3
"""Create missing current-CA secrets only in the explicitly opted-in demo."""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


ROOTS = ("arc-amp-root-ca", "arc-amp-client-root-ca")
ACTIVE_LABEL = "microsoft-certmanagement.clusterextensions.azure.com/ac-rotation-active"
OWNER = "pipeline-demo.local/certificate-repair-owner"
SOURCE_UID = "pipeline-demo.local/source-uid"
FINGERPRINT = "pipeline-demo.local/source-sha256"
NAMESPACE = "cert-manager"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments, payload=None):
    result = subprocess.run(
        arguments, input=payload, capture_output=True, timeout=240, check=False
    )
    # Never echo subprocess output: failed Kubernetes writes can include Secret data.
    require(result.returncode == 0, f"{arguments[0]} {arguments[1]} failed (exit {result.returncode}); no secret output retained.")
    return result.stdout


def kubectl(*arguments, payload=None):
    return run(["k3s", "kubectl", *arguments], payload)


def get(kind, name=None, namespace=None, allow_missing=False):
    arguments = ["get", kind]
    if name:
        arguments.append(name)
    arguments.extend(["-n", namespace] if namespace else ["-A"])
    if allow_missing:
        arguments.append("--ignore-not-found")
    output = kubectl(*arguments, "-o", "json")
    return json.loads(output) if output.strip() else None


def certificate_fingerprints(pem):
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----", pem)
    remainder = re.sub(r"-----BEGIN CERTIFICATE-----\s*[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----", "", pem)
    require(blocks and not remainder.strip(), "Trust material must contain only PEM certificates.")
    fingerprints = set()
    for block in blocks:
        der = base64.b64decode(re.sub(r"\s", "", block), validate=True)
        run(["openssl", "x509", "-inform", "DER", "-noout"], der)
        fingerprints.add(hashlib.sha256(der).hexdigest())
    return fingerprints


def ready(resource, condition="Ready"):
    return any(
        item["type"] == condition and item["status"] == "True"
        and item.get("observedGeneration", resource["metadata"].get("generation"))
        == resource["metadata"].get("generation")
        for item in resource.get("status", {}).get("conditions", [])
    )


def inspect_ca(data):
    """Validate real PEM material with OpenSSL; keep private files mode 0600."""
    with tempfile.TemporaryDirectory(prefix="pipeline-demo-ca-") as directory:
        cert = Path(directory, "certificate.pem")
        key = Path(directory, "key.pem")
        cert.write_bytes(base64.b64decode(data["tls.crt"], validate=True))
        key.write_bytes(base64.b64decode(data["tls.key"], validate=True))
        text = run(["openssl", "x509", "-in", str(cert), "-noout", "-text"]).decode()
        require("CA:TRUE" in text and "Certificate Sign" in text, "Source certificate is not a signing CA.")
        run(["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "86400"])
        run(["openssl", "verify", "-CAfile", str(cert), str(cert)])
        public_cert = run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
        public_key = run(["openssl", "pkey", "-in", str(key), "-pubout"])
        require(public_cert == public_key, "Source CA certificate and key do not match.")
        der = run(["openssl", "x509", "-in", str(cert), "-outform", "DER"])
        expires = run(["openssl", "x509", "-in", str(cert), "-noout", "-enddate"]).decode().strip()
        return hashlib.sha256(der).hexdigest(), expires.removeprefix("notAfter=")


def make_copy(source, certificate, issuer, existing, owner):
    name = source["metadata"]["name"]
    require(name in ROOTS and source["metadata"]["namespace"] == NAMESPACE, "Unexpected source CA location.")
    require(certificate["metadata"]["namespace"] == NAMESPACE
            and certificate["spec"].get("secretName") == name
            and certificate["spec"].get("isCA") is True and ready(certificate),
            f"Source Certificate {name} must be a Ready CA referencing its matching Secret.")
    require(issuer["metadata"]["name"] == f"{name}-cluster-issuer"
            and issuer["spec"].get("ca", {}).get("secretName") == f"{name}-current",
            f"Unexpected issuer reference for {name}.")
    require(source["type"] == "kubernetes.io/tls", f"Unexpected source Secret type for {name}.")
    fingerprint, expires = inspect_ca(source["data"])
    annotations = {OWNER: owner, SOURCE_UID: source["metadata"]["uid"], FINGERPRINT: fingerprint}
    labels = {ACTIVE_LABEL: name}
    if existing:
        require(existing["metadata"].get("annotations", {}).get(OWNER) == owner,
                f"Refusing to adopt or overwrite existing {name}-current.")
        require(all(existing["metadata"]["annotations"].get(k) == v for k, v in annotations.items())
                and existing["metadata"].get("labels", {}).get(ACTIVE_LABEL) == name
                and existing.get("type") == source["type"]
                and existing.get("data") == source["data"],
                f"Existing repair {name}-current differs from its source; recreate the disposable demo.")
        return None, {"name": f"{name}-current", "sha256": fingerprint, "expires": expires, "action": "revalidated"}
    conditions = issuer.get("status", {}).get("conditions", [])
    require(any(c.get("type") == "Ready" and c.get("status") == "False"
                and c.get("reason") == "ErrGetKeyPair"
                and f'secrets "{name}-current" not found' in c.get("message", "")
                for c in conditions), f"{name} does not exhibit the approved missing-secret failure.")
    result = {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": f"{name}-current", "namespace": NAMESPACE,
                     "labels": labels, "annotations": annotations},
        "type": source["type"], "data": source["data"],
    }
    return result, {"name": f"{name}-current", "sha256": fingerprint, "expires": expires, "action": "created"}


def check_controller_namespace(deployments):
    controllers = []
    for deployment in deployments:
        for container in deployment["spec"]["template"]["spec"]["containers"]:
            if container.get("name") == "cert-manager-controller":
                controllers.append((deployment, container))
    require(len(controllers) == 1, "Expected exactly one cert-manager controller.")
    deployment, container = controllers[0]
    arguments = container.get("args", [])
    # Explicit flags override the controller configuration file.
    namespace = None
    for index, argument in enumerate(arguments):
        if argument.startswith("--cluster-resource-namespace="):
            namespace = argument.split("=", 1)[1]
        elif argument == "--cluster-resource-namespace":
            namespace = arguments[index + 1]
    if namespace == "$(POD_NAMESPACE)":
        env = next((e for e in container.get("env", []) if e["name"] == "POD_NAMESPACE"), {})
        require(env.get("valueFrom", {}).get("fieldRef", {}).get("fieldPath") == "metadata.namespace",
                "Cannot resolve controller cluster-resource namespace.")
        namespace = deployment["metadata"]["namespace"]
    require(namespace == NAMESPACE, "Issuer Secret namespace differs from the approved demo configuration.")
    trust_containers = [c for d in deployments for c in d["spec"]["template"]["spec"]["containers"]
                        if c.get("name") == "trust-manager"]
    require(len(trust_containers) == 1
            and "--trust-namespace=cert-manager" in trust_containers[0].get("args", []),
            "Trust-manager source namespace must explicitly be cert-manager.")


def check_bundle(bundle, root, sources):
    selectors = [
        s["secret"] for s in bundle["spec"]["sources"]
        if s.get("secret", {}).get("selector", {}).get("matchLabels", {}).get(ACTIVE_LABEL) == root
    ]
    require(len(selectors) == 1, f"Expected one active-CA source selector in {bundle['metadata']['name']}.")
    selector = selectors[0]
    require(selector["selector"] == {"matchLabels": {ACTIVE_LABEL: root}}
            and selector.get("key") in ("tls.crt", "ca.crt") and "name" not in selector,
            "Unexpected trust-bundle source selector; refusing a guessed label repair.")
    require(selector["key"] in sources[root]["data"], "Selected trust-bundle key is missing from source CA.")
    target = bundle["spec"]["target"]
    require("configMap" in target and "key" in target["configMap"], "Expected ConfigMap trust-bundle target.")
    namespace_label = "arc-amp-client" if root == ROOTS[1] else "arc-amp-trust-bundle"
    require(target.get("namespaceSelector") == {"matchLabels": {namespace_label: "true"}},
            "Unexpected bundle destination selector; refusing guessed namespace labels.")
    return target["configMap"]["key"], selector["key"]


def wait_bundle(bundle, target_key, fingerprint):
    name = bundle["metadata"]["name"]
    deadline = time.monotonic() + 180
    while True:
        refreshed = get("bundle", name)
        selector = refreshed["spec"]["target"].get("namespaceSelector", {})
        require(not selector.get("matchExpressions"), "Unsupported bundle namespace selector.")
        labels = selector.get("matchLabels", {})
        targets = [n["metadata"]["name"] for n in get("namespaces")["items"] if all(
            n["metadata"].get("labels", {}).get(k) == v for k, v in labels.items())]
        synchronized = ready(refreshed, "Synced") and bool(targets)
        for namespace in targets:
            configmap = get("configmap", name, namespace, allow_missing=True)
            pem = configmap.get("data", {}).get(target_key, "") if configmap else ""
            if not pem or fingerprint not in certificate_fingerprints(pem):
                synchronized = False
        if synchronized:
            return
        require(time.monotonic() < deadline, f"Timed out waiting for expected CA propagation from Bundle {name}.")
        time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-demo-repair", action="store_true", required=True)
    parser.add_argument("--ownership-id", required=True)
    parser.add_argument("--pipeline-version", required=True)
    parser.add_argument("--certificate-version", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[a-f0-9-]{36}", args.ownership_id), "Invalid demo ownership identifier.")
    require((args.pipeline_version, args.certificate_version) == ("1.7.0", "1.2.0"),
            "Repair is restricted to pipeline 1.7.0 and Certificate Manager 1.2.0.")
    os.umask(0o077)
    check_controller_namespace(get("deployments")["items"])
    all_secrets = get("secrets", namespace=NAMESPACE)["items"]
    secrets = {s["metadata"]["name"]: s for s in all_secrets}
    owned = [s for s in all_secrets if s["metadata"].get("annotations", {}).get(OWNER) == args.ownership_id]
    for root in ROOTS:
        marker = secrets.get(root + "-current", {}).get("metadata", {}).get("annotations", {}).get(OWNER)
        require(marker is None or marker == args.ownership_id, "Current CA belongs to another demo repair.")
    issuers = {r: get("clusterissuer", f"{r}-cluster-issuer") for r in ROOTS}
    if not owned and all(ready(i) for i in issuers.values()):
        print("Managed issuers are Ready; no demo certificate repair required.")
        return
    print("WARNING: demo-only certificate repair; automatic CA rotation is NOT repaired.", flush=True)
    bundles = get("bundles.trust.cert-manager.io")["items"]
    namespace = get("namespace", "pipeline-demo")
    require(all(namespace["metadata"].get("labels", {}).get(label, "true") == "true"
                for label in ("arc-amp-trust-bundle", "arc-amp-client")),
            "Demo namespace has conflicting trust-bundle labels.")
    plans, evidence, bundle_checks = [], [], []
    for root in ROOTS:
        require(root in secrets, f"Source CA Secret {root} is missing.")
        matches = [b for b in bundles if any(
            s.get("secret", {}).get("selector", {}).get("matchLabels", {}).get(ACTIVE_LABEL) == root
            for s in b["spec"]["sources"])]
        require(len(matches) == 1, f"Cannot uniquely identify trust bundle for {root}.")
        bundle = matches[0]
        target_key, source_key = check_bundle(bundle, root, secrets)
        active = [s["metadata"]["name"] for s in all_secrets
                  if s["metadata"].get("labels", {}).get(ACTIVE_LABEL) == root]
        require(not active or active == [f"{root}-current"], f"Ambiguous active trust sources for {root}.")
        copy, public = make_copy(
            secrets[root], get("certificate", root, NAMESPACE), issuers[root],
            secrets.get(f"{root}-current"), args.ownership_id)
        source_pem = base64.b64decode(secrets[root]["data"][source_key], validate=True).decode()
        require(public["sha256"] in certificate_fingerprints(source_pem),
                f"Bundle source for {root} does not contain the signing CA.")
        if copy:
            plans.append(copy)
        evidence.append(public)
        bundle_checks.append((bundle, target_key, public["sha256"]))
    # Validate both roots before the first write; retries can finish a partial create.
    for resource in plans:
        kubectl("create", "-f", "-", payload=json.dumps(resource).encode())
    # Ensure the demo namespace receives both bundles before pipeline creation.
    kubectl("label", "namespace", "pipeline-demo", "arc-amp-trust-bundle=true", "arc-amp-client=true")
    for root in ROOTS:
        kubectl("wait", "--for=condition=Ready", "clusterissuer", f"{root}-cluster-issuer", "--timeout=180s")
    for bundle, target_key, fingerprint in bundle_checks:
        wait_bundle(bundle, target_key, fingerprint)
    print(json.dumps({"status": "Ready", "automaticCaRotation": False, "certificates": evidence,
                      "checkedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat()}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Certificate repair stopped: {error}") from None
