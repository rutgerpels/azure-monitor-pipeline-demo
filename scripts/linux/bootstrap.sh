#!/bin/bash
# Bootstrap the disposable single-node site; never format or erase a disk.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nfs-kernel-server nfs-common curl python3 nftables jq

if [[ ! -x /usr/local/bin/k3s ]]; then
    installer=$(mktemp)
    trap 'rm -f "$installer"' EXIT
    curl --fail --silent --show-error --location \
        https://raw.githubusercontent.com/k3s-io/k3s/v1.33.3+k3s1/install.sh -o "$installer"
    INSTALL_K3S_VERSION='v1.33.3+k3s1' sh "$installer" server \
        --disable traefik --disable servicelb --secrets-encryption --write-kubeconfig-mode 600
fi
k3s --version | grep -F 'v1.33.3+k3s1'
for attempt in {1..30}; do
    if [[ -n "$(k3s kubectl get nodes -o name)" ]]; then break; fi
    (( attempt < 30 )) || { echo 'K3s node did not register' >&2; exit 1; }
    sleep 5
done
k3s kubectl wait node --all --for=condition=Ready --timeout=180s

install -d -m 0777 /var/lib/pipeline-buffer
install -d -m 0755 /etc/exports.d
# NFS traffic never leaves this host; root squashing remains enabled.
printf '%s\n' '/var/lib/pipeline-buffer 10.80.0.4(rw,sync,no_subtree_check,root_squash) 127.0.0.1(rw,sync,no_subtree_check,root_squash)' \
    > /etc/exports.d/pipeline-demo.exports
exportfs -ra
systemctl enable --now nfs-server
k3s kubectl create namespace pipeline-demo --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl apply -f /home/demoadmin/demo/kubernetes/storage.yaml
