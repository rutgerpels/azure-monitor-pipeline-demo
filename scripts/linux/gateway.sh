#!/bin/bash
# Install a pinned gateway; only local clients can reach the node ports.
set -euo pipefail
pipeline=${1:?Pipeline name required}
[[ "$pipeline" =~ ^[a-z][a-z0-9-]+$ ]] || exit 1
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! command -v helm >/dev/null; then
    work=$(mktemp -d)
    trap 'rm -f "$work/helm.tar.gz" "$work/helm.tar.gz.sha256sum"; rm -rf "$work/linux-amd64"; rmdir "$work"' EXIT
    curl -fsSL https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz -o "$work/helm.tar.gz"
    curl -fsSL https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz.sha256sum -o "$work/helm.tar.gz.sha256sum"
    expected=$(cut -d ' ' -f 1 "$work/helm.tar.gz.sha256sum")
    printf '%s  %s\n' "$expected" "$work/helm.tar.gz" | sha256sum -c -
    tar -xzf "$work/helm.tar.gz" -C "$work"
    install "$work/linux-amd64/helm" /usr/local/bin/helm
fi
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update traefik
helm upgrade --install demo-gateway traefik/traefik --version 41.6.1 \
    --namespace pipeline-demo --values /home/demoadmin/demo/kubernetes/gateway-values.yaml \
    --wait --timeout 5m
for mapping in baseline:1514 cef:1515 filtered:1516; do
    entry=${mapping%:*}
    port=${mapping#*:}
    k3s kubectl apply -f - <<YAML
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: demo-$entry
  namespace: pipeline-demo
  labels:
    demo-gateway: pipeline
spec:
  entryPoints:
    - $entry
  routes:
    - match: HostSNI(\`*\`)
      services:
        - name: $pipeline-service
          port: $port
YAML
done
k3s kubectl wait --for=condition=Ready pod -l "pipeline=$pipeline" -n pipeline-demo --timeout=300s
k3s kubectl get pods,pvc,svc -n pipeline-demo
