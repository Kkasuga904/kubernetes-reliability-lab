# Experiment 07 — HPA (CPU utilization is relative to requests)

## Question

How does the HPA decide to scale, and why does changing `requests.cpu`
change scaling without changing real load?

## Hypothesis

HPA computes `utilization = avg actual CPU / requests.cpu (100m)` per Pod.
At target 50% (~50m avg), sustained `/cpu` load scales 3 Pods toward the max
6; when load stops, replicas scale back after the stabilization window (~60s).
Doubling `requests` to 200m would halve the reported utilization for identical
load — same traffic, different scaling decision.

## Setup

- metrics-server installed (see `scripts/create-cluster.sh`)
- HPA `min 3 / max 6 / target CPU 50%`, Pod requests `100m`

## Procedure

```bash
kubectl -n reliability-lab get hpa web -w &
watch -n5 'kubectl -n reliability-lab get hpa web; kubectl -n reliability-lab get pods'
kubectl -n reliability-lab describe hpa web | grep -A5 Metrics
# generate load (~4 min):
WORKERS=4 scripts/cpu-load.sh 240
# observe: kubectl top pods, hpa TARGETS column, desired replicas climbing
kubectl -n reliability-lab top pods
# after load stops, watch scale-down (takes minutes due to stabilization window)
```

## Evidence to collect

- `kubectl get hpa` TARGETS (e.g. `120%/50%`) and REPLICAS over time
- `kubectl top pods` actual millicores vs 100m request
- `kubectl describe hpa` events (`SuccessfulRescale`)
- Scale-down delay after load ends

## Expected behavior

Utilization well above 50% -> step-ups toward max 6 within a few minutes;
after load, delayed step-down. The math follows `sum(actual)/sum(requests)`.

## Observed behavior

**PASS** (validated 2026-09-18, kind + metrics-server).

Baseline: 3 Pods, `cpu: 2%/50%`. Generated load with 4 parallel loops against
`/cpu?milliseconds=200` for 240s:

```text
NAME   REFERENCE        TARGETS      MINPODS  MAXPODS  REPLICAS
web    Deployment/web   cpu: 75%/50%  3        6        6
top pods: one Pod at 453m, others ~3-6m   (requests=100m, limits=500m)
SuccessfulRescale: New size: 6; reason: cpu resource utilization (percentage of request) above target
```

After load stopped: `6 -> 5 -> 3` (`All metrics below target`), back to
`cpu: 3%/50%` within ~3 minutes.

Load-generation caveat (honest): `kubectl port-forward svc/web` pins to a
**single** Pod, so one Pod ran at ~453% of its request while the rest idled.
The HPA averages across Pods (~80m avg vs 100m request = ~75-80%), which still
exceeded the 50% target and drove the scale-up. With real balanced traffic the
same math applies per-Pod-average — the mechanism, not the distribution, is
what this validates.

## Explanation

HPA computed average utilization against the declared `requests.cpu=100m`, not
against the 500m limit or Node capacity. The single hot Pod's ~450m dominated
the average and pushed it over 50%, hence 6 replicas. For the same observed CPU
values, a 400m request would produce roughly one quarter of the reported
utilization and would likely fall below the 50% target. That configuration was
not run, so no scaling outcome is claimed for it. Scale-down returned through
6->5->3 after load; the configured 60s stabilization window contributes to the
delay, alongside HPA sync and metrics timing.

## What this mechanism guarantees

- Reactive capacity tracking of *measured* CPU vs the *declared* request baseline.

## What it does NOT guarantee

- Instant scaling (metrics pipeline + sync period delays of 1-3 min are normal).
- Correct scaling if `requests` are wrong: under-declared requests inflate
  utilization and over-scale; over-declared requests mask real pressure.
- Scaling on latency, queue depth, or memory without custom metrics.

## Production implications

- Right-size `requests` from measured p95/p99 usage first; HPA targets second.
- Expect and test scale-up latency; keep headroom for spikes (don't run at 90%).
- For spiky or latency-sensitive workloads, add KEDA/custom metrics; on EKS,
  Cluster Autoscaler must also provision Nodes or Pods stay Pending.
