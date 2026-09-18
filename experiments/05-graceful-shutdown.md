# Experiment 05 — Graceful shutdown during rolling update

## Question

During `kubectl rollout restart`, do in-flight requests (`/slow?duration=20`)
survive? Does the preStop hook + `terminationGracePeriodSeconds: 30` matter?

## Hypothesis

Old Pods receive SIGTERM, are removed from Endpoints, finish in-flight requests
within the grace period, and log the shutdown markers. A request longer than the
grace period is cut off. "Zero downtime" holds only while requests drain faster
than the grace budget and replacements become Ready in time.

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

SIGTERM -> preStop sleep (5s) -> uvicorn drains (≤25s) -> Endpoints removal
propagates -> replacement Pods Ready -> rollout completes. Requests exceeding
30s are killed.

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
`maxUnavailable: 1` and zero failed requests in this run. The >grace-period
contrast case (`/slow?duration=60` vs 30s grace) was **not executed** — no claim
is made about it beyond the design reading.

## Explanation

SIGTERM arrived after endpoint removal had begun (helped by the 5s preStop
sleep); uvicorn's 25s graceful window (inside the 30s Pod grace) let the 20s
request finish before process exit. "Zero downtime" held here because the
request (20s) fit inside the drain budget (30s) AND replacements became Ready in
time — change either condition and the conclusion changes, which is exactly what
the guarantees table says.

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
