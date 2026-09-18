# Experiment 01 — Pod failure and self-healing

## Question

A running Pod dies (`kubectl delete pod`). What actually restores service capacity,
and does the Service send traffic to a replacement before it is Ready?

## Hypothesis

The Deployment's ReplicaSet controller observes desired (3) vs actual replicas,
creates a replacement Pod. After the readinessProbe succeeds and endpoint
state propagates, the replacement becomes eligible for new Service traffic.
With 3 replicas, surviving Ready endpoints should continue serving during one
Pod's replacement; this does not guarantee every in-flight request survives.

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
shortfall and creates a replacement. The replacement is not eligible for new
Service traffic until `readinessProbe` on `/ready` succeeds and the resulting
EndpointSlice/data-plane state propagates; until then its EndpointSlice
condition is `ready: false`.

## Observed behavior

**PARTIAL** (validated 2026-09-18, kind v0.33.0 / k8s v1.37.0).
ReplicaSet replacement was observed, but a continuous request trace was not
captured, so no zero-request-loss or continuity result is claimed.

Deleted `web-d55f6549f-fxvsx` while 2 other Pods were Ready. Within seconds:

```text
39s  Normal  Killing           pod/web-d55f6549f-fxvsx   Stopping container web
39s  Normal  SuccessfulCreate  replicaset/web-d55f6549f  Created pod: web-d55f6549f-zhjm5
39s  Normal  Scheduled         pod/web-d55f6549f-zhjm5   Successfully assigned ... to reliability-lab-worker
38s  Normal  Started           pod/web-d55f6549f-zhjm5   Container started
```

`kubectl get pods` showed the replacement `Running` shortly after; two surviving
Pods remained Ready (no rollout, no restarts on survivors, restartCount
untouched). Continuous Service responses were not recorded during this run.

## Explanation

The deleted Pod object was never resurrected. The ReplicaSet controller's
reconciliation loop observed actual < desired replicas and created a *new* Pod
object (`SuccessfulCreate` by `replicaset/...`, not by kubelet). Scheduling,
image pull (already cached), container start, then readiness gating happened as
separate steps, each visible in events. Any continuity during replacement would
depend on the *surviving* Ready endpoints, not on the replacement being fast;
this run did not capture a continuous request trace to validate that outcome.

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
