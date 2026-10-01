#!/bin/bash
set -euo pipefail
subscription=${1:?Subscription required}
group=${2:?Resource group required}
cluster=${3:?Cluster name required}
custom_oid=${4:?Custom location object ID required}
export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! command -v az >/dev/null; then
    installer=$(mktemp)
    curl --fail --silent --show-error --location https://aka.ms/InstallAzureCLIDeb -o "$installer"
    bash "$installer"
    rm -f "$installer"
fi
az extension add --name connectedk8s --only-show-errors
az login --identity --allow-no-subscriptions --output none
trap 'az account clear' EXIT
# Role propagation can lag VM identity creation.
for attempt in {1..24}; do
    if az group show --name "$group" --subscription "$subscription" --output none; then break; fi
    (( attempt < 24 )) || exit 1
    sleep 10
done
az connectedk8s connect --name "$cluster" --resource-group "$group" \
    --location westeurope --subscription "$subscription"
az connectedk8s enable-features --name "$cluster" --resource-group "$group" \
    --features cluster-connect custom-locations --custom-locations-oid "$custom_oid" \
    --subscription "$subscription"
