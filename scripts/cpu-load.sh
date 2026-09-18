#!/usr/bin/env bash
# Generate CPU load against the Service for the HPA experiment (07).
# Usage: scripts/cpu-load.sh [seconds]  (default 240)
# Runs N parallel loops hitting /cpu?milliseconds=200 via port-forward.
set -euo pipefail
DURATION="${1:-240}"
WORKERS="${WORKERS:-4}"

kubectl -n reliability-lab port-forward svc/web 18080:80 >/tmp/pf-load.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID; kill 0 2>/dev/null || true' EXIT
sleep 4

end=$((SECONDS + DURATION))
for ((w = 0; w < WORKERS; w++)); do
  (
    while [ $SECONDS -lt $end ]; do
      curl -s -o /dev/null "http://127.0.0.1:18080/cpu?milliseconds=200" || true
    done
  ) &
done
echo "load running for ${DURATION}s with ${WORKERS} workers..."
wait
echo "load done"
