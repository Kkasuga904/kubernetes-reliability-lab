# Experiment 01 — Pod failure and self-healing

## Question

A running Pod dies (`kubectl delete pod`). What actually restores service capacity,
and does the Service send traffic to a replacement before it is Ready?

## Hypothesis

The Deployment's ReplicaSet controller observes desired (3) vs actual replicas,
creates a replacement Pod, and the Service only routes to it after the
readinessProbe succeeds. One Pod dying should not cause user-visible downtime
with 3 replicas.

## Setup

- `replicas: 3`, Service `web` selects `app: web`
- All Pods Ready (`kubectl -n reliability-lab get pods`)

## Procedure

```bash
kubectl -n reliability-lab get pods -o wide
VICTIM=$(kubectl -n reliability-lab get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl -n reliability-lab delete pod "$VICTIM" &
kubectl -n reliability-lab get pods -w
kubectl -n reliability-lab get events --sort-by=.lastTimestamp | tail -20
kubectl -n reliability-lab get endpointslice -l kubernetes.io/service-name=web -o yaml
kubectl -n reliability-lab describe rs -l app=web | head -30
```

## Evidence to collect

- `kubectl get pods -w` (Terminating -> new Pod Pending/ContainerCreating/Running)
- `kubectl get events` (Killing, SuccessfulCreate, Scheduled, Pulled, Started)
- EndpointSlice addresses before/after (Ready conditions)
- ReplicaSet `desired/current/ready` counts

## Expected behavior

Per the ReplicaSet reconciliation loop: the controller notices the replica
shortfall and creates a replacement. The new Pod receives traffic only after
`readinessProbe` on `/ready` succeeds; until then its EndpointSlice condition
is `ready: false`.

## Observed behavior

**PASS** (validated 2026-09-18, kind v0.33.0 / k8s v1.37.0).

Deleted `web-d55f6549f-fxvsx` while 2 other Pods were Ready. Within seconds:

```text
39s  Normal  Killing           pod/web-d55f6549f-fxvsx   Stopping container web
39s  Normal  SuccessfulCreate  replicaset/web-d55f6549f  Created pod: web-d55f6549f-zhjm5
39s  Normal  Scheduled         pod/web-d55f6549f-zhjm5   Successfully assigned ... to reliability-lab-worker
38s  Normal  Started           pod/web-d55f6549f-zhjm5   Container started
```

`kubectl get pods` showed the replacement `Running` shortly after; the two
surviving Ready Pods kept the Service answered throughout (no rollout, no
restarts on survivors, restartCount untouched).

(Note: at delete time a third Pod was already `Terminating` from an HPA
scale-down 3->2 — see experiment 07. The replacement still converged the
ReplicaSet to the HPA-desired count.)

## Explanation

The deleted Pod object was never resurrected. The ReplicaSet controller's
reconciliation loop observed actual < desired replicas and created a *new* Pod
object (`SuccessfulCreate` by `replicaset/...`, not by kubelet). Scheduling,
image pull (already cached), container start, then readiness gating happened as
separate steps, each visible in events. Service continuity came from the
*surviving* Ready endpoints, not from the replacement being fast.

## What this mechanism guarantees

- Desired replica count is continuously reconciled (self-healing of *capacity*).

## What it does NOT guarantee

- No request loss for in-flight requests on the killed Pod.
- No downtime if too few replicas remain (e.g. `maxUnavailable` exceeded, or all Pods on one Node).
- Data or session preservation: the replacement starts clean.

## Production implications

- Run ≥2 replicas across Nodes/zones; add Pod anti-affinity and topology spread.
- Monitor `kube_deployment_status_replicas_unavailable` and rollout staleness.
- On EKS: same controller logic, plus Node failure domains (multi-AZ node groups) matter.
