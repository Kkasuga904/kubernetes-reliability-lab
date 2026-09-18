#!/usr/bin/env bash
# Deploy all manifests in dependency-safe order, then wait for rollout.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/pdb.yaml
kubectl apply -f k8s/hpa.yaml

kubectl -n reliability-lab rollout status deployment/web --timeout=180s
kubectl -n reliability-lab get pods,svc,pdb,hpa
