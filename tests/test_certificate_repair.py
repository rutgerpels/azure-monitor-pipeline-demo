"""Test repair decisions without Azure or cluster writes; validate real PEMs locally."""

import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import io
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "repair", Path(__file__).parents[1] / "scripts/linux/repair_certificates.py"
)
repair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repair)
OWNER = "00000000-0000-0000-0000-000000000001"


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.root = repair.ROOTS[0]
        self.source = {
            "metadata": {"name": self.root, "namespace": "cert-manager", "uid": "source-id",
                         "resourceVersion": "123", "ownerReferences": [{"uid": "do-not-copy"}]},
            "type": "kubernetes.io/tls", "data": {"tls.crt": "certificate", "tls.key": "private"},
        }
        self.certificate = {
            "metadata": {"namespace": "cert-manager", "generation": 1},
            "spec": {"secretName": self.root, "isCA": True},
            "status": {"conditions": [{"type": "Ready", "status": "True", "observedGeneration": 1}]},
        }
        self.issuer = {
            "metadata": {"name": self.root + "-cluster-issuer"},
            "spec": {"ca": {"secretName": self.root + "-current"}},
            "status": {"conditions": [{
                "type": "Ready", "status": "False", "reason": "ErrGetKeyPair",
                "message": f'Error getting keypair for CA issuer: secrets "{self.root}-current" not found',
            }]},
        }
        self.inspector = patch.object(repair, "inspect_ca", return_value=("public-fingerprint", "tomorrow"))
        self.inspector.start()
        self.addCleanup(self.inspector.stop)

    def plan(self, existing=None):
        return repair.make_copy(self.source, self.certificate, self.issuer, existing, OWNER)

    def test_only_sanitized_copy_and_public_evidence(self):
        resource, evidence = self.plan()
        self.assertEqual(resource["data"], self.source["data"])
        self.assertEqual(resource["metadata"]["labels"], {repair.ACTIVE_LABEL: self.root})
        self.assertNotIn("ownerReferences", resource["metadata"])
        self.assertNotIn("resourceVersion", resource["metadata"])
        self.assertNotIn("private", json.dumps(evidence))
        self.assertEqual(resource["metadata"]["annotations"][repair.SOURCE_UID], "source-id")

    def test_existing_own_copy_is_revalidated_without_write(self):
        resource, _ = self.plan()
        plan, evidence = self.plan(resource)
        self.assertIsNone(plan)
        self.assertEqual(evidence["action"], "revalidated")

    def test_foreign_copy_is_rejected(self):
        existing, _ = self.plan()
        existing["metadata"]["annotations"][repair.OWNER] = "another-owner"
        with self.assertRaisesRegex(RuntimeError, "Refusing to adopt"):
            self.plan(existing)

    def test_changed_source_or_copy_is_rejected(self):
        existing, _ = self.plan()
        for field in ("tls.key", "tls.crt"):
            with self.subTest(field=field):
                changed = copy.deepcopy(existing)
                changed["data"][field] = "different"
                with self.assertRaisesRegex(RuntimeError, "differs from its source"):
                    self.plan(changed)
        self.source["metadata"]["uid"] = "replacement-source"
        with self.assertRaisesRegex(RuntimeError, "differs from its source"):
            self.plan(existing)

    def test_unrelated_keypair_error_is_not_repaired(self):
        self.issuer["status"]["conditions"][0]["message"] = "permission denied"
        with self.assertRaisesRegex(RuntimeError, "approved missing-secret failure"):
            self.plan()

    def test_source_readiness_and_issuer_reference_are_required(self):
        self.certificate["status"]["conditions"][0]["observedGeneration"] = 0
        with self.assertRaisesRegex(RuntimeError, "Ready CA"):
            self.plan()
        self.certificate["status"]["conditions"][0]["observedGeneration"] = 1
        self.issuer["spec"]["ca"]["secretName"] = "unrelated"
        with self.assertRaisesRegex(RuntimeError, "Unexpected issuer"):
            self.plan()

    def test_bundle_selector_must_match_exactly(self):
        bundle = {"metadata": {"name": "arc-amp-trust-bundle"}, "spec": {
            "sources": [{"secret": {"selector": {"matchLabels": {repair.ACTIVE_LABEL: self.root}},
                                    "key": "tls.crt"}}],
            "target": {"configMap": {"key": "ca.crt"}, "namespaceSelector": {"matchLabels": {"arc-amp-trust-bundle": "true"}}},
        }}
        self.assertEqual(repair.check_bundle(bundle, self.root, {self.root: self.source}), ("ca.crt", "tls.crt"))
        bundle["spec"]["sources"][0]["secret"]["selector"]["matchLabels"]["extra"] = "required"
        with self.assertRaisesRegex(RuntimeError, "Unexpected trust-bundle"):
            repair.check_bundle(bundle, self.root, {self.root: self.source})

    def test_cluster_resource_namespace_is_resolved(self):
        deployment = {"metadata": {"namespace": "cert-manager"}, "spec": {"template": {"spec": {
            "containers": [{
                "name": "cert-manager-controller",
                "image": "registry/cert-manager-controller:version",
                "args": ["--cluster-resource-namespace=$(POD_NAMESPACE)"],
                "env": [{"name": "POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}}],
            }, {"name": "trust-manager", "args": ["--trust-namespace=cert-manager"]}],
        }}}}
        repair.check_controller_namespace([deployment])
        deployment["metadata"]["namespace"] = "unrelated"
        with self.assertRaisesRegex(RuntimeError, "namespace differs"):
            repair.check_controller_namespace([deployment])

    def test_failed_write_does_not_disclose_payload(self):
        result = subprocess.CompletedProcess([], 1, b"private", b"private")
        with patch.object(repair.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as error:
                repair.kubectl("create", "-f", "-", payload=b"private")
        self.assertNotIn("private", str(error.exception))

    def test_opt_in_is_required(self):
        with patch("sys.argv", ["repair"]), patch.object(repair, "get") as get:
            with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                repair.main()
            get.assert_not_called()

    def test_unapproved_versions_fail_before_cluster_access(self):
        with patch("sys.argv", ["repair", "--allow-demo-repair", "--ownership-id", OWNER,
                               "--pipeline-version", "1.8.0", "--certificate-version", "1.2.0"]):
            with patch.object(repair, "get") as get, self.assertRaisesRegex(RuntimeError, "restricted to"):
                repair.main()
            get.assert_not_called()

    def test_full_repair_validates_both_roots_before_writing(self):
        sources, certificates, issuers, bundles = {}, {}, {}, {}
        for root in repair.ROOTS:
            sources[root] = copy.deepcopy(self.source)
            sources[root]["metadata"]["name"] = root
            sources[root]["data"] = {"tls.crt": base64.b64encode(root.encode()).decode(), "tls.key": "private"}
            certificates[root] = copy.deepcopy(self.certificate)
            certificates[root]["spec"]["secretName"] = root
            issuers[root + "-cluster-issuer"] = copy.deepcopy(self.issuer)
            issuers[root + "-cluster-issuer"]["metadata"]["name"] = root + "-cluster-issuer"
            issuers[root + "-cluster-issuer"]["spec"]["ca"]["secretName"] = root + "-current"
            issuers[root + "-cluster-issuer"]["status"]["conditions"][0]["message"] = f'secrets "{root}-current" not found'
            bundles[root] = {
                "metadata": {"name": root, "generation": 1},
                "spec": {"sources": [{"secret": {"selector": {"matchLabels": {repair.ACTIVE_LABEL: root}}, "key": "tls.crt"}}],
                         "target": {"configMap": {"key": "ca.crt"}, "namespaceSelector": {"matchLabels": {
                             "arc-amp-client" if root == repair.ROOTS[1] else "arc-amp-trust-bundle": "true"}}}},
                "status": {"conditions": [{"type": "Synced", "status": "True", "observedGeneration": 1}]},
            }

        def get(kind, name=None, namespace=None, allow_missing=False):
            if kind == "deployments":
                return {"items": []}
            if kind == "secrets":
                return {"items": list(sources.values())}
            if kind == "clusterissuer":
                return issuers[name]
            if kind == "certificate":
                return certificates[name]
            if kind == "bundles.trust.cert-manager.io":
                return {"items": list(bundles.values())}
            if kind == "bundle":
                return bundles[name]
            if kind == "namespaces":
                return {"items": [{"metadata": {"name": "pipeline-demo", "labels": {
                    "arc-amp-trust-bundle": "true", "arc-amp-client": "true"}}}]}
            if kind == "namespace":
                return {"metadata": {"name": "pipeline-demo"}}
            if kind == "configmap":
                return {"data": {"ca.crt": name}}
            self.fail(f"Unexpected read {kind}")

        argv = ["repair", "--allow-demo-repair", "--ownership-id", OWNER,
                "--pipeline-version", "1.7.0", "--certificate-version", "1.2.0"]
        with patch("sys.argv", argv), patch.object(repair, "get", side_effect=get), \
                patch.object(repair, "check_controller_namespace"), \
                patch.object(repair, "certificate_fingerprints", return_value={"public-fingerprint"}), \
                patch.object(repair, "kubectl") as kubectl, redirect_stdout(io.StringIO()) as output:
            old_umask = os.umask(0o077)
            self.addCleanup(os.umask, old_umask)
            certificates[repair.ROOTS[1]]["spec"]["isCA"] = False
            with self.assertRaisesRegex(RuntimeError, "Ready CA"):
                repair.main()
            kubectl.assert_not_called()
            certificates[repair.ROOTS[1]]["spec"]["isCA"] = True
            repair.main()
            creates = [c for c in kubectl.call_args_list if c.args[0] == "create"]
            self.assertEqual(len(creates), 2)
            self.assertEqual(json.loads(creates[0].kwargs["payload"])["metadata"]["name"], repair.ROOTS[0] + "-current")
            self.assertNotIn("private", output.getvalue())
            self.assertIn('"status": "Ready"', output.getvalue())
            # Partial failure can leave the first copy; only the missing second is created on retry.
            current = json.loads(creates[0].kwargs["payload"])
            sources[current["metadata"]["name"]] = current
            kubectl.reset_mock()
            repair.main()
            self.assertEqual(len([c for c in kubectl.call_args_list if c.args[0] == "create"]), 1)
            # A healthy issuer must not hide foreign ownership.
            for issuer in issuers.values():
                issuer["status"]["conditions"] = [{"type": "Ready", "status": "True"}]
            current["metadata"]["annotations"][repair.OWNER] = "foreign-owner"
            with self.assertRaisesRegex(RuntimeError, "another demo repair"):
                repair.main()

    def test_bundle_polls_actual_propagation_even_when_synced(self):
        bundle = {"metadata": {"name": "bundle", "generation": 1},
                  "spec": {"target": {"configMap": {"key": "ca.crt"}}},
                  "status": {"conditions": [{"type": "Synced", "status": "True"}]}}
        responses = iter([None, {"data": {"ca.crt": "new-ca"}}])

        def get(kind, *args, **kwargs):
            if kind == "bundle":
                return bundle
            if kind == "namespaces":
                return {"items": [{"metadata": {"name": "pipeline-demo"}}]}
            return next(responses)

        with patch.object(repair, "get", side_effect=get), \
                patch.object(repair, "certificate_fingerprints", return_value={"expected"}), \
                patch.object(repair.time, "sleep") as sleep:
            repair.wait_bundle(bundle, "ca.crt", "expected")
            sleep.assert_called_once()


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required")
class CertificateMaterialTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.old_umask = os.umask(0o077)
        self.addCleanup(os.umask, self.old_umask)

    def generate(self, name, days=3, ca=True):
        key, cert = self.path / f"{name}.key", self.path / f"{name}.crt"
        result = subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", str(days),
            "-subj", "/CN=Disposable Test CA", "-keyout", str(key), "-out", str(cert),
            "-addext", f"basicConstraints=critical,CA:{str(ca).upper()}",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign" if ca else "keyUsage=digitalSignature",
        ], capture_output=True, check=False, timeout=30)
        self.assertEqual(result.returncode, 0, "Local OpenSSL fixture generation failed")
        return {"tls.crt": base64.b64encode(cert.read_bytes()).decode(),
                "tls.key": base64.b64encode(key.read_bytes()).decode()}

    def test_valid_ca(self):
        data = self.generate("valid")
        fingerprint, expires = repair.inspect_ca(data)
        self.assertEqual(len(fingerprint), 64)
        self.assertIn("GMT", expires)
        self.assertEqual(repair.certificate_fingerprints(base64.b64decode(data["tls.crt"]).decode()), {fingerprint})
        other = self.generate("other")
        self.assertNotIn(fingerprint, repair.certificate_fingerprints(base64.b64decode(other["tls.crt"]).decode()))
        with self.assertRaisesRegex(RuntimeError, "only PEM certificates"):
            repair.certificate_fingerprints(base64.b64decode(data["tls.crt"]).decode()
                                           + base64.b64decode(data["tls.key"]).decode())

    def test_rejects_near_expiry(self):
        with self.assertRaises(RuntimeError):
            repair.inspect_ca(self.generate("expiring", days=1))

    def test_rejects_leaf_certificate(self):
        with self.assertRaisesRegex(RuntimeError, "not a signing CA"):
            repair.inspect_ca(self.generate("leaf", ca=False))

    def test_rejects_mismatched_key(self):
        data = self.generate("first")
        data["tls.key"] = self.generate("second")["tls.key"]
        with self.assertRaisesRegex(RuntimeError, "do not match"):
            repair.inspect_ca(data)


if __name__ == "__main__":
    unittest.main()
