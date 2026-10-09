# Argo orphan ownership and retention

This runbook keeps Argo orphan warnings as evidence rather than as a deletion
command. Git remains the desired-state authority. The inventory is read-only,
metadata-only, and never includes Secret data.

## Baseline — 2026-10-09

The versioned object-level capture is
[`argo-orphan-baseline-2026-10-09.json`](argo-orphan-baseline-2026-10-09.json).
It was collected through the canonical operator kubeconfig on Kubernetes
`v1.36.3`; no live resource was mutated.

| Signal | Baseline |
|---|---:|
| Applications with `OrphanedResourceWarning` | 19 |
| Maximum repeated warning count | 954 |
| Unique GVK/namespace/name rows | 949 |
| Rows whose object disappeared during capture | 29 |
| ACTIVE | 54 |
| OPERATOR_MANAGED | 84 |
| RETAINED | 712 |
| STALE | 0 |
| UNKNOWN | 99 |

The warnings are repeated by Application. The object list is therefore the
authority for counts and classification, not the sum of warning messages.
The 29 unresolved rows are deliberately retained as `UNKNOWN` and must be
re-captured before any decision; they are not assumed deleted.

The largest families are Longhorn `Setting` (116), `Engine` (102), `Volume`
(102), `VolumeAttachment` (102), `Replica` (101), Aqua security reports (104
across report kinds), Pods (50), ServiceAccounts (37), Jobs (35), and Velero
`BackupRepository` (34). The largest namespaces are `longhorn-system` (548),
`velero` (173), and `kube-system` (56). Restore-drill namespaces are retained
as temporary evidence, not stale candidates.

## Scope and exception policy

The `applications` and `infrastructure` AppProjects now enumerate the
namespaces rendered by their Git roots instead of monitoring `namespace: '*'`.
Restore-drill, default, kube-public, and other unrelated namespaces therefore
do not amplify every Application warning.

The exception lists are limited to deterministic operator API kinds: Aqua
reports, VPA checkpoints, CNPG/reloader ConfigMaps, Longhorn state, Velero
state, and Velero Kopia maintenance Jobs. Pods, Deployments, StatefulSets,
DaemonSets, Secrets, PVCs, and unknown kinds remain visible to the inventory.
Resource tracking remains annotation-based. No RBAC or AppProject role was
changed, and no new global `resource.exclusions` rule was added.

## Retention and garbage collection

- All repository CronJobs have bounded successful/failed history and now set
  `ttlSecondsAfterFinished: 86400` on generated Jobs where that is safe.
- Fixed-name Argo-managed bootstrap Jobs intentionally have no TTL: deleting
  them after completion would make Argo recreate them on the next comparison.
- Velero schedules retain backups for 336 hours (14 days); restore and backup
  objects remain retained until their drill/retention owner closes them.
- The existing Velero/Kopia maintenance-job policy uses Kubernetes TTL and the
  repository maintenance configuration retains two latest maintenance Jobs.
- CNPG clusters, Barman object stores, Longhorn volumes/attachments, ESO
  resources, PVCs, Secrets, and restore-drill state are `RETAINED` unless a
  separate human-approved data-owner decision changes their classification.
- The live backup audit reported 17 uncovered PVC rows, all in active restore
  drill namespaces. This is a retention/restore evidence gap, not permission
  to delete those objects.

## Read-only inventory and comparison

```bash
just argo-orphan-inventory /tmp/argo-orphans.json
just argo-orphan-compare docs/operations/argo-orphan-baseline-2026-10-09.json /tmp/argo-orphans-compared.json
```

The comparison keys by UID when available and falls back to GVK/namespace/name
for objects that disappeared during capture. New rows include UID, owner
references, Argo tracking metadata, finalizers, managedFields, age and
classification. A disappearance is not attributed to Kubernetes GC, Argo
prune, TTL, or manual deletion without audit/event evidence.

Prometheus now records the de-duplicated project-level signal
`kube_ops:argocd_orphaned_resources_unique` and alerts on presence and growth.
The JSON inventory remains the source for unique object identity and lifecycle
classification; the metric is intentionally not treated as an object dump.

## Cleanup batches — preparation only

| Batch | Contents | Current action | Risk / rollback |
|---|---|---|---|
| B0 | Longhorn, Velero, Aqua, VPA and controller-generated children | Retain; operator lifecycle | High if removed; upstream operator reconciliation or snapshot/backup recovery is required |
| B1 | Restore-drill PVCs, Pods, ConfigMaps, Backups, Restores and reports | Retain until named drill closure | High; restore evidence and isolated namespace are the rollback boundary |
| B2 | PVC/PV/Volume/VolumeAttachment, CNPG/ESO state, Secrets and backups | Retain; no deletion plan | Critical; restore/data-owner approval required |
| B3 | 99 UNKNOWN rows, including 29 unresolved capture rows | No deletion proposal | Unknown; re-inventory and human classification required |
| B4 | STALE_SAFE candidates | Empty at baseline (`STALE=0`) | No approved deletion batch exists |

No deletion command is included in this change. Any future cleanup must attach
an immutable object-level inventory, explicitly name approved UIDs, export a
pre-delete snapshot, and obtain human approval before a separate deletion
change. PVC, PV, volume, snapshot, backup, Secret, operator resource, and
UNKNOWN deletion always require explicit validation.

## Evidence verdict for this change

`ORPHAN_WARNINGS_BEFORE=19 application warnings (max 954)`

`ORPHAN_UNIQUE_BEFORE=949`

`ORPHAN_UNIQUE_AFTER=NOT_MEASURED_BEFORE_RECONCILIATION`

`OPERATOR_GENERATED=84 classified by ownerReferences, plus retained operator API state`

`ACTUALLY_STALE=0`

`UNKNOWN=99`

`RETENTION_POLICY=PASS_WITH_17_RESTORE_DRILL_COVERAGE_GAPS`

`MONITORING_SIGNAL=PASS`

`CLEANUP_BATCHES=B0-B4 PREPARED; NO LIVE DELETION`

`HUMAN_APPROVAL_NEEDED=YES_FOR_ANY_DELETION_OR_RECLASSIFICATION`
