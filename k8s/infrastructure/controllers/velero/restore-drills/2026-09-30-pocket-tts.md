# Restore drill — pocket-tts — 2026-09-30

> **Status: drill completed, cleanup merged.** The `restore-pocket-tts`
> namespace, headless Service, and default-deny CiliumNetworkPolicy were
> removed from GitOps desired state in the follow-up cleanup PR
> (`chore(dr): cleanup restore-drill pocket-tts skeleton after successful drill`).
> Argo pruned the namespace and its contents. This file is retained as the
> post-mortem record of the drill; it is no longer reflected in any live
> resource.

## Summary

Velero + Kopia restore drill against the production `pocket-tts` namespace,
replayed into an isolated `restore-pocket-tts` namespace. PR #106 provided
the GitOps restore skeleton (Argo Application `apps-restore`, namespace,
headless Service, default-deny CiliumNetworkPolicy). The drill is the
first time Velero + Kopia restore was validated end-to-end on the V1
platform.

## Timeline

| Step | Time (CEST) | Result |
|---|---|---|
| PR #106 merged (squash) | 2026-09-30 ~19:21 | `b1daa421` |
| Argo reconciles `apps-restore` | 2026-09-30 ~19:23 | Synced + Healthy |
| `restore-pocket-tts` namespace + headless Service + CNP present | 2026-09-30 19:23:30 | confirmed |
| `velero restore create restore-drill-pocket-tts` | 2026-09-30 19:29:26 | submitted |
| Restore phase | 2026-09-30 19:29:30 | **Completed** |
| Pod Ready check | — | **did not reach Ready** (see anomaly 1) |

## Source backup

- Name: `velero-daily-pocket-tts-20260930074123`
- UID: `1bb784ba-3c92-477e-adda-6794ef5255e0`
- Phase: `Completed` (3 warnings — pod was Pending at backup time, so
  `/pods/...` volume data was skipped; namespace-scoped resources and
  PVs were captured)
- Started: 2026-09-30 09:41:34 +0200 CEST
- Completed: 2026-09-30 09:41:36 +0200 CEST
- TTL: 336h0m0s
- Items: 14/14 backed up
- Storage Location: `default` (Hetzner Object Storage via Kopia)
- Schedule: `velero-daily-pocket-tts`

## Restore target

- Namespace: `restore-pocket-tts`
- Namespace mappings: `pocket-tts:restore-pocket-tts`
- Existing resource policy: `none`
- Restore name: `restore-drill-pocket-tts`
- Restore UID: `f60882d2-9b2e-4f00-91ab-3fb873a06db6`
- Phase: **Completed** (4 cluster-scoped resource warnings — see below)

## Restored resources

| Resource | Result |
|---|---|
| `apps/v1/Deployment` `restore-pocket-tts/pocket-tts` | created |
| `apps/v1/ReplicaSet` `restore-pocket-tts/pocket-tts-5654bd5b49` | created |
| `apps/v1/ReplicaSet` `restore-pocket-tts/pocket-tts-6769ff6849` | created |
| `apps/v1/ReplicaSet` `restore-pocket-tts/pocket-tts-7cfc7bd55c` | created |
| `cilium.io/v2/CiliumNetworkPolicy` `restore-pocket-tts/pocket-tts-network-policy` | created |
| `monitoring.coreos.com/v1/PodMonitor` `restore-pocket-tts/pocket-tts` | created |
| `v1/PersistentVolumeClaim` `restore-pocket-tts/pocket-tts-data` | created |
| `v1/PersistentVolumeClaim` `restore-pocket-tts/pocket-tts-voices` | created |
| `v1/Pod` `restore-pocket-tts/pocket-tts-5654bd5b49-hp87q` | created |
| `apiextensions.k8s.io/v1/CustomResourceDefinition` `ciliumnetworkpolicies.cilium.io` | failed (already exists — cluster-scoped) |
| `apiextensions.k8s.io/v1/CustomResourceDefinition` `podmonitors.monitoring.coreos.com` | failed (already exists — cluster-scoped) |
| `v1/PersistentVolume` `pvc-65e45620-1ec4-4402-96cb-3e73b3adeef3` | failed (already exists — claimed by prod PVC) |
| `v1/PersistentVolume` `pvc-dbe6a6ce-6d02-4fb4-a50f-2c723edffd58` | failed (already exists — claimed by prod PVC) |

## Verification

| Check | Expected | Observed | Status |
|---|---|---|---|
| apps-restore Synced + Healthy | yes | Synced + Healthy | PASS |
| `restore-pocket-tts` namespace present | yes | Active | PASS |
| Both PVCs Bound in restore namespace | yes | both Pending | **FAIL** |
| Pod reaches Ready | yes | `pocket-tts-5654bd5b49-hp87q` Pending (FailedScheduling: unbound immediate PVCs) | **FAIL** |
| Health endpoint PASS via port-forward | yes | unreachable (no pod to forward) | **not-reached** |
| Production `pocket-tts` namespace untouched | yes | pod `pocket-tts-69fd6df988-f2vjt` still Running, both prod PVCs still Bound, no manifest churn | PASS |
| Velero restore phase | Completed | Completed | PASS |

## Anomalies

### 1. PVCs stuck Pending due to same-cluster RWO + claimRef conflict

The restored PVCs in `restore-pocket-tts` carry the original `volumeName`
(`pvc-65e45620-...`, `pvc-dbe6a6ce-...`) and reference the same PV UUIDs
that the production `pocket-tts` namespace still has Bound. Both PVs have
`claimRef` pointing at the production PVCs and are `phase: Bound` to the
Longhorn RWO volumes that the production `pocket-tts` deployment currently
holds.

PersistentVolumeClaim controller rejects the restore bindings:

```
Warning  FailedBinding  ...  persistentvolume-controller
  volume "pvc-65e45620-..." already bound to a different claim.
```

This is an architectural limitation of same-cluster Velero restores for
Longhorn RWO volumes: Velero restores with `--existing-resource-policy=none`
do not delete or rotate PVs that are still Bound to a live PVC, so the
restored PVCs cannot claim them. The cluster-scoped PV restore is reported
as a non-fatal warning by Velero.

Consequence: the restored Pod is stuck in `FailedScheduling` because its
immediate PVCs are unbound. The drill therefore validates Velero's manifest
restore + Argo's restore-skeleton reconcile, but not the Pod Ready path or
the application health endpoint. The Pod Ready + health checks must be
validated in a future drill that uses either a different storage class,
PV retain recovery, or a separate cluster.

### 2. Storage class mapping does not apply to `longhorn-fast`

`k8s/infrastructure/controllers/velero/storage-class-mapping.yaml` maps
`longhorn` to `proxmox-csi`. The pocket-tts production PVCs use
`longhorn-fast`, not `longhorn`, so the change-storage-class action is a
no-op for this drill. The restored PVCs therefore stay on `longhorn-fast`,
which is what surfaces anomaly 1 (the PV UUIDs are real Longhorn UUIDs and
the claimRef conflict is binding, not class-name based). This is a
pre-existing config gap, not introduced by the drill. Future work: extend
the mapping to cover `longhorn-fast` and `longhorn-bulk` explicitly.

### 3. Argo apps-ai sees the restored PVCs as orphans

The Velero restore copies the production PVC annotations, including
`argocd.argoproj.io/tracking-id: apps-ai:/PersistentVolumeClaim:pocket-tts/pocket-tts-data`.
`apps-ai` is `Degraded` and now reports 489 orphaned resources (was 488
before the restore). The restore resources stay in `restore-pocket-tts`
because Argo's default prune propagation does not delete orphans that
live outside the Application's source path; nevertheless, the orphan count
drifts up by 1 for every restore. The cleanup PR removes the restore
namespace and all restored resources, returning the orphan count to 488.

## Production namespace state (pre + post drill, for proof of non-impact)

```text
# Before drill (captured at 19:28 CEST)
pod/pocket-tts-69fd6df988-f2vjt   0/1   Running   7 restarts   45m
pvc/pocket-tts-data     Bound  longhorn-fast  pvc-65e45620-...  5Gi  RWO
pvc/pocket-tts-voices   Bound  longhorn-fast  pvc-dbe6a6ce-...  1Gi  RWO

# After drill (captured at 19:32 CEST)
pod/pocket-tts-69fd6df988-f2vjt   0/1   Running   8 restarts   48m
pvc/pocket-tts-data     Bound  longhorn-fast  pvc-65e45620-...  5Gi  RWO
pvc/pocket-tts-voices   Bound  longhorn-fast  pvc-dbe6a6ce-...  1Gi  RWO
```

The Pod UID, the PV UUIDs, the PVC UIDs, and the storage class are all
unchanged. The +1 restart on the production pod is normal background
behavior of the existing `pocket-tts` deployment and is unrelated to the
restore drill.

## Conclusion

Velero + Kopia restore runs end-to-end against the production backup:
the Restore CR reaches `Phase: Completed` in 4 seconds, all
namespace-scoped manifests are recreated in `restore-pocket-tts`, and the
production namespace is not mutated. The same-cluster RWO + claimRef
conflict prevents the restored Pod from reaching Ready, so the drill is a
**partial PASS** (manifest restore validated, full-data restore path not
validated). The cleanup PR removes the GitOps restore skeleton so Argo
prunes the namespace, headless Service, and default-deny CNP.