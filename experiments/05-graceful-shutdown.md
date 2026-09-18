# Experiment 05 — Graceful shutdown during rolling update

## Question

During `kubectl rollout restart`, do in-flight requests (`/slow?duration=20`)
survive? Does the preStop hook + `terminationGracePeriodSeconds: 30` matter?

## Hypothesis

During Pod termination, EndpointSlice readiness changes, the preStop hook, and
SIGTERM/application shutdown should provide a bounded opportunity to stop new
routing and finish in-flight work. Their propagation and ordering are not an
unconditional guarantee. The tested claim is limited to whether this one 20s
request completes within the configured budget.

## Setup

- Default Deployment (`terminationGracePeriodSeconds: 30`, `preStop: sleep 5`,
  uvicorn `--timeout-graceful-shutdown 25`).
- Port-forward the Service.

## Procedure

```bash
kubectl -n reliability-lab port-forward svc/web 18080:80 >/tmp/pf.log 2>&1 &
sleep 4
# Start a slow request in the background (20s < 30s grace -> should survive)
curl -s "http://127.0.0.1:18080/slow?duration=20" -w '\nHTTP %{http_code} time=%{time_total}s\n' &
SLOW_PID=$!
sleep 2
kubectl -n reliability-lab rollout restart deployment/web
kubectl -n reliability-lab rollout status deployment/web --timeout=180s
wait $SLOW_PID
# Evidence:
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "killing\|terminat" | tail -10
kubectl -n reliability-lab logs -l app=web --tail=50 | grep -i "SIGTERM\|shutdown\|/slow" | tail -20
kubectl -n reliability-lab get endpointslice -l kubernetes.io/service-name=web -o yaml | grep -c "ready: true"

# Contrast case (commentary only if run): /slow?duration=60 exceeds the 30s
# grace period and is expected to be terminated mid-flight (SIGKILL after grace).
```

## Evidence to collect

- Slow request HTTP code + total time (expect 200 in ~20s despite rollout)
- App logs: `Received SIGTERM`, `/slow finished`, `Shutdown complete`
- Events ordering: endpoint removal vs `Killing`
- Rollout status with `maxUnavailable: 1`

## Expected behavior

Kubernetes begins termination, marks the endpoint terminating/not ready, runs
the 5s preStop hook, and then sends SIGTERM to the container. EndpointSlice and
data-plane propagation occur asynchronously; no strict cross-component order is
assumed. The hook and Uvicorn shutdown share the 30s Pod termination budget.
This run expects the selected 20s request to finish, not every request.

## Observed behavior

**PASS** (validated 2026-09-18, kind).

Started `GET /slow?duration=20` through the Service, then `kubectl rollout
restart` mid-flight:

```text
{"status":"ok","slept_s":20}
HTTP_CODE=200 TIME=20.02s        # survived the rollout, answered in full
```

Serving Pod's log shows the drain working as designed:

```text
/slow started duration=20s
Received SIGTERM - starting graceful shutdown (in-flight requests drain first)
...
/slow finished duration=20s
"GET /slow?duration=20 HTTP/1.1" 200 OK
```

All old Pods logged `Received SIGTERM`; rollout completed with
`maxUnavailable: 1`, and the single measured request did not fail. The >grace-period
contrast case (`/slow?duration=60` vs 30s grace) was **not executed** — no claim
is made about it beyond the design reading.

## Explanation

The observed request had already started before termination and completed before
process exit. The 5s preStop hook and Uvicorn's graceful shutdown operated
inside the shared 30s Pod termination budget. This single observation does not
establish exact EndpointSlice-to-SIGTERM ordering, general zero downtime, or
survival for all requests.

## What this mechanism guarantees

- A *bounded* drain window (30s here), not infinite patience.

## What it does NOT guarantee

- Zero downtime unconditionally: long requests, slow readiness of replacements,
  `maxUnavailable` mis-sizing, or clients with no retry can still see errors.
- Ordering of endpoint propagation vs SIGTERM without the preStop buffer.

## Production implications

- Set `terminationGracePeriodSeconds` > app drain timeout > longest expected request; load-test the boundary.
- Keep the preStop sleep small and measure endpoint propagation delay.
- Clients need timeouts + retries; servers need idempotency for retried requests.
- On EKS: same Pod semantics; add ALB target-group deregistration delay alignment.
