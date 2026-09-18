# Experiment 02 — Readiness failure (Running != Ready)

## Question

Only the readiness probe fails. Is the Pod restarted? Does it still receive Service traffic?

## Hypothesis

The Pod stays `Running` with `Ready=False`; its EndpointSlice entry becomes
`ready: false` (or may be removed), and the container is NOT restarted
(`restartCount` unchanged). After that state reaches the data plane, readiness
controls eligibility for *new* Service traffic, not process lifecycle.

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

kubelet stops reporting Ready; the EndpointSlice controller marks the endpoint
unready or removes it. After propagation, new Service traffic is routed to the
other Ready Pods. Existing connections and in-flight requests are not drained
by the probe. No container restart occurs.

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
victim's endpoint `ready: false`. Once that state propagated through the
Service data plane, the endpoint was no longer eligible for *new* Service
traffic. The experiment did not measure propagation latency or existing
connection behavior. The container kept running untouched — readiness is not
a process supervisor. Contrast with experiment 03, where the same 500 from
`/health` caused a restart.

## What this mechanism guarantees

- Probe failure makes a Pod unready; after EndpointSlice and data-plane
  propagation it is ineligible for new Service traffic.

## What it does NOT guarantee

- Restarting or fixing the broken process (that is liveness's job).
- Draining in-flight requests already sent to the Pod.
- Immediate removal: probe cadence, EndpointSlice updates, kube-proxy or other
  data-plane propagation, and connection reuse add timing and implementation details.
- Detection of deep application errors the probe endpoint does not check.

## Production implications

- Make `/ready` check real dependencies needed to serve (DB, downstream), but keep it cheap and fast.
- Never gate readiness on things unrelated to serving (e.g. a background cron) — you will silently shed capacity.
- Alert on `Ready=False` duration and endpoints-ready count, not just restarts.
