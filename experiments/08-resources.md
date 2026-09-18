# Experiment 08 — Resource limits under pressure (CPU throttling vs OOMKilled)

## Question

What happens when a Pod hits its CPU limit vs its memory limit — and which one restarts the container?

## Hypothesis

CPU is *compressible*: exceeding `limits.cpu (500m)` throttles the process
(slower responses, no restart, no event beyond throttling metrics). Memory is
*incompressible*: exceeding `limits.memory (256Mi)` gets the container
OOMKilled (exit 137, `restartCount` +1, event `OOMKilled`). `requests` affect
scheduling/HPA math; `limits` bound runtime usage.

## Setup

- Default resources: `requests 100m/128Mi`, `limits 500m/256Mi`
- Deliberately conservative so the lab stays stable; pressure is applied briefly.

## Procedure

```bash
# CPU pressure: observe throttling, not restarts
kubectl -n reliability-lab top pods
WORKERS=8 scripts/cpu-load.sh 120 &
kubectl -n reliability-lab get pods -w   # expect NO restarts
kubectl -n reliability-lab describe pod -l app=web | grep -i "restart\|throttl" | head

# Memory pressure (OPTIONAL, not run here): use an isolated Pod with the same
# 256Mi memory limit; without a limit this would not test container-limit OOM.
kubectl -n reliability-lab run oom --image=polinux/stress --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"oom","image":"polinux/stress","resources":{"limits":{"memory":"256Mi"}},"args":["stress","--vm","1","--vm-bytes","400M","--timeout","30s"]}]}}'
kubectl get pod oom -w
kubectl describe pod oom | grep -i "oom\|terminated\|exit" | head -10
kubectl delete pod oom --ignore-not-found
```

## Evidence to collect

- CPU phase: `top pods` near 500m with `restartCount` unchanged; collect cgroup
  or container throttling metrics before claiming measured throttling
- Memory phase: `OOMKilled`, exit code 137, restart/eviction events
- EndpointSlice continuity during CPU throttle (Pods stay Ready but slow)

## Expected behavior

CPU pressure degrades latency without restarts; memory excess kills the container.
Requests and limits have different roles. Direct throttling evidence and the
memory phase must be collected before treating both mechanisms as observed.

## Observed behavior

**PARTIAL** — CPU phase validated 2026-09-18 (kind); memory/OOM probe
deliberately not run (see below).

8 parallel loops against `/cpu?milliseconds=500` for 90s:

```text
top pods: one Pod at 499m (≈500m limit), others ~3m; memory flat at 38-39Mi
restartCount: 0 -> 0 on every Pod (before and after identical)
```

No restarts, no evictions, no OOM events under sustained CPU pressure near the
limit boundary. (HPA also scaled 3->6 during this run — same averaging math as
experiment 07.) The OOM probe (`stress --vm ... 400M`) was **not executed**: it
risks Node pressure on a small kind cluster for a claim (`OOMKilled`, exit 137)
already covered by mechanism documentation rather than new insight. It stays
labeled optional, not validated.

## Explanation

The 499m observation near a 500m CPU limit is consistent with CPU limiting, and
restartCount proves the container was not restarted. Direct CFS throttling
metrics and latency measurements were not collected, so this run does not by
itself prove the amount of throttling or its latency impact. The memory/OOM
phase was not run. `requests.cpu=100m` was demonstrably the HPA utilization
baseline; the separate runtime effect of `limits.cpu=500m` remains only
partially evidenced here.

## What this mechanism guarantees

- Configuration semantics: CPU limits are enforced through throttling, while
  exceeding a container memory limit can result in an OOM kill. This experiment
  directly observed neither CFS throttling metrics nor the OOM case.

## What it does NOT guarantee

- Performance under throttle (tail latency can collapse while everything looks "Running").
- That limits prevent OOMs elsewhere: a too-low memory limit *causes* kills;
  a missing limit risks whole-Node pressure and kubelet evictions.

## Production implications

- Set memory requests/limits from workload measurements and failure policy; set
  CPU limits only after measuring throttle
  (`container_cpu_cfs_throttled_seconds_total`), or omit CPU limits and rely on requests + quota.
- Alert on throttling ratio and OOM events separately — they need opposite fixes
  (raise CPU limit vs fix leak / raise memory / reduce footprint).
- On EKS: Node size and bin-packing make requests/limits a cost lever too.
