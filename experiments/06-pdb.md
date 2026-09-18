# Experiment 06 — PodDisruptionBudget (Eviction API scope)

## Question

What does `minAvailable: 2` actually block — and what does it *not* block?

## Hypothesis

PDB constrains voluntary disruptions requested through the Eviction API, such
as `kubectl drain`, by refusing an eviction that would violate the budget. It
does NOT directly control a normal Deployment rolling update; that uses the
Deployment's `maxUnavailable`/`maxSurge` strategy. It also does not prevent a
Pod/container crash, liveness restart, direct `kubectl delete pod`, Node failure,
or application failure. Direct deletion is not an Eviction API request, so the
PDB does not gate it.

## Setup

- 3 Pods Ready, PDB `minAvailable: 2` (`allowedDisruptions` should be 1).
- 2-worker kind cluster (drain has somewhere to move Pods).

## Procedure

```bash
kubectl -n reliability-lab get pdb web -o yaml | grep -A3 disruptionsAllowed
# Voluntary: drain one worker (respects PDB)
NODE=$(kubectl get nodes --no-headers | grep -v control-plane | head -1 | awk '{print $1}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data &
sleep 20
kubectl -n reliability-lab get pods -o wide
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | grep -i "evict\|drain\|disruption" | tail -10
kubectl uncordon "$NODE"
# Direct deletion bypasses the Eviction API and therefore the PDB
VICTIM=$(kubectl -n reliability-lab get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl -n reliability-lab delete pod "$VICTIM" --now
kubectl -n reliability-lab get pods
```

## Evidence to collect

- `disruptionsAllowed: 1` before drain
- During drain: evictions proceed for at most 1 Pod; Pods reschedule on the other worker
- `kubectl delete pod` succeeds immediately regardless of PDB
- Events mentioning eviction API vs Killing

## Expected behavior

Drain is throttled/partially blocked by the PDB budget; direct deletion is not.
With `minAvailable: 2` and 3 replicas, at most one Pod can be voluntarily
disrupted at a time.

## Observed behavior

**PASS** (validated 2026-09-18, kind with 2 workers).

Baseline: `minAvailable=2`, `allowedDisruptions=1`, 3 Pods Ready.

1. `kubectl drain reliability-lab-worker`: evicted 1 web Pod
   (`pod/web-69d4948847-kqknx evicted`), which rescheduled on the other worker;
   `node/reliability-lab-worker drained`. Voluntary disruption within budget: allowed.
2. `kubectl drain reliability-lab-worker2` (all 3 Pods now on it): one more
   eviction, then the drain **stalled and timed out** —
   `error when evicting pods/...: global timeout reached`. PDB status at that
   point: `allowedDisruptions=0 currentHealthy=2 desiredHealthy=2`. The budget,
   not the drain command, set the limit.
3. `kubectl uncordon` both nodes: Pending Pod scheduled, back to 3 Running.
4. `kubectl delete pod <victim>`: succeeded **instantly** despite the PDB;
   ReplicaSet created a replacement. Direct Pod deletion bypasses the Eviction
   API and therefore the PDB.

## Explanation

`kubectl drain` evicts through the eviction API, which the API server refuses
(HTTP 429) when the PDB budget is exhausted — hence stall, not failure of the
Pods. `kubectl delete` uses the Pod delete API, which PDB does not gate. The
experiment shows both APIs side by side: same cluster, same PDB, opposite
outcomes. A PDB is a budget on voluntary evictions, not an availability shield.

## What this mechanism guarantees

- The API server rejects an Eviction API request when admitting it would
  violate the selected Pods' disruption budget.

## What it does NOT guarantee

- Protection against Pod/container crashes, liveness restarts, Node loss,
  application failure, or direct `delete pod`.
- Availability by itself: with 3 replicas and `minAvailable: 2`, losing 2 Pods
  to real failures still leaves 1 serving.

## Production implications

- Always pair PDBs with topology spread / multi-AZ so the "remaining 2" are not on the same Node.
- Deployment rolling updates are governed by `maxUnavailable`/`maxSurge`, not
  directly by the PDB. Size the Deployment strategy and PDB consistently for
  the availability objective because they cover different disruption paths.
- On EKS: PDBs gate Cluster Autoscaler scale-down and node-group upgrades — a too-strict PDB blocks upgrades.
