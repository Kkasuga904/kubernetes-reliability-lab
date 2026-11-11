#!/usr/bin/env bash
# Create the kind cluster (1 control-plane + 2 workers) and install metrics-server.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config k8s/kind-config.yaml

# metrics-server is required for HPA (experiment 07). kind does not ship it.
metrics_server_manifest="$(mktemp)"
trap 'rm -f "$metrics_server_manifest"' EXIT
curl --fail --silent --show-error --location --output "$metrics_server_manifest" \
  https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
echo "3c7f57cdbee0f57fb0259a150e8f6d6cb4f29d72d1aa5dce8803151dd6d4c2a1  $metrics_server_manifest" | sha256sum --check
kubectl apply -f "$metrics_server_manifest"
kubectl -n kube-system patch deployment metrics-server \
  --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl wait --for=condition=Available -n kube-system deployment/metrics-server --timeout=180s
kubectl get nodes
