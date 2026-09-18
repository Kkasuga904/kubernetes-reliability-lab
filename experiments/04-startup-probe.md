# Experiment 04 — Startup probe (protecting slow starts from premature liveness kills)

## Question

A container needs ~30s to initialize. Without a startupProbe, does liveness kill it
prematurely? With one, is it protected?

## Hypothesis

Initial hypothesis before running: without a startupProbe, the liveness probe
(initialDelay 15s) would fail during initialization and restart the container.
With the startupProbe's nominal 60s budget, liveness/readiness evaluation is
suppressed until `/health` succeeds once. The observations below show why the
30s no-startup case did not actually restart and the 45s case did.

## Setup

- Two phases on the same Deployment: startupProbe present (default) vs removed.
- Slow start simulated with `STARTUP_DELAY_SECONDS=30` in the ConfigMap.

## Procedure

```bash
# Phase A: WITH startupProbe (default manifest)
kubectl -n reliability-lab patch configmap web-config --type=merge -p '{"data":{"STARTUP_DELAY_SECONDS":"30"}}'
kubectl -n reliability-lab rollout restart deployment/web
kubectl -n reliability-lab rollout status deployment/web --timeout=180s
kubectl -n reliability-lab get pods
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "startup\|liveness\|killing" | tail -10

# Phase B: WITHOUT startupProbe (temporarily remove it)
kubectl -n reliability-lab patch deployment web --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/startupProbe"}]'
kubectl -n reliability-lab rollout restart deployment/web
kubectl -n reliability-lab get pods -w   # watch for CrashLoopBackOff / restarts
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "liveness\|killing\|backoff" | tail -15

# Restore:
kubectl -n reliability-lab patch configmap web-config --type=merge -p '{"data":{"STARTUP_DELAY_SECONDS":"0"}}'
kubectl -n reliability-lab apply -f k8s/deployment.yaml
kubectl -n reliability-lab rollout status deployment/web --timeout=180s
```

## Evidence to collect

- Phase A: steady rollout, no restarts, Ready after ~30-40s
- Phase B: `restartCount` climbing, `CrashLoopBackOff`, `Liveness probe failed` + `Killing` events before the app ever finishes starting
- `kubectl describe pod` probe timings

## Expected behavior

Startup probe disables liveness/readiness until success (or `failureThreshold ×
periodSeconds` = 60s expiry). Removing it exposes slow starts to liveness kills.

## Observed behavior

**PASS with a nuance worth keeping** (validated 2026-09-18, kind).

- Phase A (delay 30s, startupProbe present): rollout succeeded. Events showed
  only `Startup probe failed: ... statuscode: 500` warnings; **restarts stayed 0**,
  all Pods Ready after ~40s. The 60s startup allowance (12 x 5s) covered the delay.
- Phase B (delay 30s, startupProbe removed): only `Liveness probe failed`
  warnings, **no restarts**. The hypothesis as written was too strong — with these
  numbers the liveness budget (`initialDelay 15s` + 3 x 10s = ~45s of failures)
  still exceeded the 30s delay, so the container survived without protection.
- Phase B' (delay 45s, startupProbe removed): `Container web failed liveness
  probe, will be restarted`, restarts climbed (1+), Pods churned before serving
  usefully — the premature-kill loop, reproduced.
- Restored via `STARTUP_DELAY_SECONDS=0` + `kubectl apply -f k8s/deployment.yaml`;
  rollout succeeded, restarts 0.

## Explanation

Whether a slow start dies without a startupProbe is pure arithmetic: liveness
tolerance here is ~45s from container start. A 30s delay fits inside it (scary
but lucky); a 45s delay does not (restart loop). The startupProbe replaces luck
with an explicit 60s init budget during which liveness/readiness are not
evaluated. Size protection from p99 startup latency, not from the happy path —
this experiment is the reason.

## What this mechanism guarantees

- Liveness and readiness probes are suppressed while startupProbe is still
  within its configured failure budget; startupProbe failure beyond that
  budget triggers a container restart.

## What it does NOT guarantee

- Startup completing within the window (exceed it and the container is still killed).
- Readiness after startup (readiness must still pass independently).

## Production implications

- Always set a startupProbe when cold starts are slow (JVM warm-up, model loads, migrations).
- Size the allowance from p99 startup latency, not the mean.
- On EKS the mechanism is identical; only startup latency sources differ (image pull across AZs, EBS attach).
