# Experiment 03 — Liveness failure (restart, not traffic gating)

## Question

Only the liveness probe fails. How does the evidence differ from a readiness failure?

## Hypothesis

kubelet kills and restarts the container (`restartCount` +1, `LastState.Terminated`
with reason `Error`/`OOMKilled`-style exit), events show `Unhealthy ... Liveness
probe failed` followed by `Killing`, and brief capacity loss occurs while the
container restarts. Unlike readiness, this is a restart mechanism, not traffic
gating or a guarantee that the application is repaired.

## Setup

- 3 Ready Pods; pick one victim.

## Procedure

```bash
VICTIM=$(kubectl -n reliability-lab get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl -n reliability-lab get pod "$VICTIM" -o jsonpath='{.status.containerStatuses[0].restartCount}'; echo
kubectl -n reliability-lab exec "$VICTIM" -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/admin/fail-liveness?fail=true', data=b'').read())"
sleep 45
kubectl -n reliability-lab get pod "$VICTIM" -o jsonpath='{.status.containerStatuses[0].restartCount}'; echo
kubectl -n reliability-lab describe pod "$VICTIM" | grep -B2 -A8 "Last State\|Restart Count\|Liveness"
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "$VICTIM\|liveness\|killing" | tail -10
kubectl -n reliability-lab logs "$VICTIM" --previous --tail=5 || true
```

## Evidence to collect

- `restartCount` increments; `lastState.terminated` appears
- Events: `Liveness probe failed` -> `Killing container`
- EndpointSlice flaps as the container restarts and re-passes readiness
- `kubectl logs --previous` shows pre-restart tail

## Expected behavior

After `failureThreshold × periodSeconds` of failing `/health`, kubelet restarts
the container. Readiness also fails during the restart, so traffic is gated
until probes pass again.

## Observed behavior

**PASS** (validated 2026-09-18, kind).

Injected `liveness_fail=true` into `web-d55f6549f-ssr2s`. After ~60s:

```text
restartCount: 0 -> 1,  phase=Running
Warning  Unhealthy  pod/web-d55f6549f-ssr2s  Liveness probe failed: HTTP probe failed with statuscode: 500
Normal   Killing    pod/web-d55f6549f-ssr2s  Container web failed liveness probe, will be restarted
Normal   Started    pod/web-d55f6549f-ssr2s  Container started
describe: Last State: Terminated, Reason: Error / Restart Count: 1
```

Comparison with experiment 02 on the same Pod: readiness-500 gave
`Ready=False` + `ready=false` endpoint + restartCount 0; liveness-500 gave a
kill + restart + `lastState.terminated`. The container self-recovered because
the failure flag is in-memory (reset on restart) — modeling a wedged process,
not a persistent misconfiguration.

## Explanation

After `failureThreshold x periodSeconds` of failing `/health`, kubelet killed
the container and started a fresh one. Traffic was also briefly gated because
readiness fails while the container restarts — liveness recovery is not
hitless, it is just automatic.

## What this mechanism guarantees

- After the configured failures, kubelet restarts the container without human action.

## What it does NOT guarantee

- Correct diagnosis (a too-aggressive liveness probe *causes* outages by
  restart-looping a healthy-but-slow container — see experiment 04).
- No traffic loss during the restart window.
- Preservation of local state.
- Repair of persistent configuration, dependency, or application defects; the
  same failure may recur after restart.

## Production implications

- Keep liveness checks minimal ("is the process stuck?"), never dependent on
  external systems — otherwise a downstream outage restart-loops your fleet.
- Prefer long `failureThreshold`/intervals for liveness; keep readiness strict.
- Alert on restart rate (`increase(kube_pod_container_status_restarts_total)`), with runbooks distinguishing liveness vs OOMKilled.
