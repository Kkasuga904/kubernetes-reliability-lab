# Experiment 02 — Readiness failure (Running != Ready)

## Question

Only the readiness probe fails. Is the Pod restarted? Does it still receive Service traffic?

## Hypothesis

The Pod stays `Running` with `Ready=False`, is removed from the Service
EndpointSlice, and the container is NOT restarted (`restartCount` unchanged),
because readiness gates *traffic*, not *process lifecycle*.

## Setup

- 3 Ready Pods; pick one victim Pod.

## Procedure

```bash
VICTIM=$(kubectl -n reliability-lab get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl -n reliability-lab exec "$VICTIM" -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/admin/fail-readiness?fail=true', data=b'').read())"
# or via port-forward: curl -XPOST http://127.0.0.1:18080/admin/fail-readiness?fail=true (affects one Pod behind the Service)
sleep 15
kubectl -n reliability-lab get pod "$VICTIM" -o wide
kubectl -n reliability-lab describe pod "$VICTIM" | grep -A5 Readiness
kubectl -n reliability-lab get endpointslice -l kubernetes.io/service-name=web -o yaml | grep -B2 -A6 "$VICTIM\|ready:"
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "$VICTIM\|readiness\|unhealthy"
# recover:
kubectl -n reliability-lab exec "$VICTIM" -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/admin/fail-readiness?fail=false', data=b'').read())"
```

> Note: POST via the Service may hit a different Pod; `exec` into the victim
> targets it deterministically.

## Evidence to collect

- `pod.status.phase` (expect `Running`) vs `conditions: Ready=False`
- `restartCount` unchanged
- EndpointSlice entry for victim: `ready: false` / removed
- Events: `Unhealthy ... Readiness probe failed` with NO `Killing`/restart

## Expected behavior

kubelet stops reporting Ready; EndpointSlice controller removes the endpoint;
Service traffic goes to the other 2 Pods. No container restart occurs.

## Observed behavior

**PASS** (validated 2026-09-18, kind).

Injected `readiness_fail=true` into victim `web-d55f6549f-ssr2s` (restartCount 0).
After ~20s:

```text
pod phase=Running  Ready=False  restartCount=0   # unchanged
EndpointSlice: 10.244.2.6 ready=true / 10.244.1.6 ready=true / 10.244.2.8(victim) ready=false
Warning  Unhealthy  pod/web-d55f6549f-ssr2s  Readiness probe failed: HTTP probe failed with statuscode: 500
```

No `Killing`, no restart, no `lastState.terminated`. After `fail=false`, the Pod
returned to Ready with restartCount still 0.

## Explanation

kubelet stopped reporting Ready; the EndpointSlice controller marked the
victim's endpoint `ready: false`; kube-proxy stopped sending it *new* Service
traffic. The container kept running untouched — readiness is a traffic gate
evaluated by kubelet, not a process supervisor. Contrast with experiment 03,
where the same 500 from `/health` caused a kill.

## What this mechanism guarantees

- Failing Pods stop receiving *new* Service traffic quickly (~`periodSeconds × failureThreshold`).

## What it does NOT guarantee

- Restarting or fixing the broken process (that is liveness's job).
- Draining in-flight requests already sent to the Pod.
- Detection of deep application errors the probe endpoint does not check.

## Production implications

- Make `/ready` check real dependencies needed to serve (DB, downstream), but keep it cheap and fast.
- Never gate readiness on things unrelated to serving (e.g. a background cron) — you will silently shed capacity.
- Alert on `Ready=False` duration and endpoints-ready count, not just restarts.
