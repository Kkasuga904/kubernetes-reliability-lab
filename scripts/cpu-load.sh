#!/usr/bin/env bash
# Generate CPU load against the Service for the HPA experiment (07).
# Usage: scripts/cpu-load.sh [seconds]  (default 240)
# Runs N parallel loops hitting /cpu?milliseconds=200 via port-forward.
set -euo pipefail
DURATION="${1:-240}"
WORKERS="${WORKERS:-4}"

kubectl -n reliability-lab port-forward svc/web 18080:80 >/tmp/pf-load.log 2>&1 &
PF_PID=$!
WORKER_PIDS=()

cleanup() {
  kill "$PF_PID" 2>/dev/null || true
  for pid in "${WORKER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM
sleep 4

if ! kill -0 "$PF_PID" 2>/dev/null; then
  echo "port-forward failed to start; see /tmp/pf-load.log" >&2
  exit 1
fi

end=$((SECONDS + DURATION))
for ((w = 0; w < WORKERS; w++)); do
  (
    while [ $SECONDS -lt $end ]; do
      curl -s -o /dev/null "http://127.0.0.1:18080/cpu?milliseconds=200" || true
    done
  ) &
  WORKER_PIDS+=("$!")
done
echo "load running for ${DURATION}s with ${WORKERS} workers..."
for pid in "${WORKER_PIDS[@]}"; do
  wait "$pid"
done
echo "load done"
