#!/usr/bin/env bash
# Create the kind cluster (1 control-plane + 2 workers) and install metrics-server.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config k8s/kind-config.yaml

# metrics-server is required for HPA (experiment 07). kind does not ship it.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server \
  --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl wait --for=condition=Available -n kube-system deployment/metrics-server --timeout=180s
kubectl get nodes
