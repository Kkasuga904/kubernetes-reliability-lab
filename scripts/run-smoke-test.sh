#!/usr/bin/env bash
# Smoke test: port-forward the Service and check every user-facing endpoint.
# Fails loudly (set -e) so CI can gate on it.
set -euo pipefail

kubectl -n reliability-lab rollout status deployment/web --timeout=120s

kubectl -n reliability-lab port-forward svc/web 18080:80 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID' EXIT
sleep 5

BASE=http://127.0.0.1:18080
curl -fsS "$BASE/"            | grep -q reliability-lab
curl -fsS "$BASE/health"      | grep -q ok
curl -fsS "$BASE/ready"       | grep -q ok
curl -fsS "$BASE/cpu?milliseconds=50" | grep -q ok
echo "SMOKE OK: / /health /ready /cpu all returned ok"
