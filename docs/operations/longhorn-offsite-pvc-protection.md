# Longhorn off-site protection for retained PVCs

Status: the target is **proposed and not deployed** pending GitHub admission and primary-backup verification. First restore proofs are recorded in
`dr-restore-evidence-2026-10-20.json`. Once #947 is merged and Argo has
reconciled, the global `default` recurring-job assignment will be retired;
until then it remains operational. Only PVCs and retained volumes with an explicit recurring-job label
remain in this transitional protection policy. Velero/Kopia or CNPG/Barman is
the preferred steady-state mechanism for application data; Longhorn backups
are not inferred from the presence of a PVC and are not a reason to keep a
blanket policy.

## Native capability and target

The installed Longhorn chart is 1.12.1. Its native `defaultBackupStore`
configuration supports an S3-compatible target, a credential Secret and a
poll interval. The target is the existing Hetzner bucket
`smadja-dev-homelab-backups`, under the `longhorn/` prefix. Velero continues
to own its existing `velero/` prefix.

ESO creates `longhorn-hetzner-credentials` in `longhorn-system` from the same
two Doppler keys already used by Velero. No credential value is stored in Git.
The endpoint is the existing non-secret Hetzner endpoint.

The cluster target is `BackupTarget/default`, available against the existing
Hetzner S3 endpoint. The protection changes do not change a PVC volume size,
StorageClass, replica count or data path. The Immich Redis PVC only gains
Longhorn recurring-job source labels; no application restart is required.

## Seven explicit transitional PVCs

The official `persistent-offsite-backup` recurring job runs daily at 03:17 UTC,
retains seven backups per volume and allows one concurrent backup. The seven
currently declared PVCs are explicitly marked as the recurring-job source:

- `agentgateway/agentgateway-state` — SQLite; snapshot/restore validation
  must run `PRAGMA integrity_check` and a read-only application-level check.
- `atlantis-system/atlantis-pilot-data` — protect the dormant pilot state;
  GitHub App readiness remains a separate blocker.
- `immich/redis-data-immich-redis-master-0` — Redis AOF restore sur copie qualifié ;
  conserver la protection Longhorn explicite tant que la restauration applicative
  complète d’Immich n’est pas validée.
- `invoice-ninja/invoice-ninja-public` — application public data pending
  qualification of its Velero/Kopia primary copy.
- `invoice-ninja/invoice-ninja-storage` — application storage pending the same
  one-copy qualification.
- `matrix/matrix-synapse-media` — Matrix media retained until a verified
  Velero/Kopia replacement is accepted.
- `sure/sure-storage` — application storage retained until its primary copy is
  verified.

Two additional retained Longhorn volumes, `listmonk/listmonk-uploads` and
`twenty/twenty-storage`, are unmounted data-only volumes with explicit labels
in the live inventory. They are not represented by current PVC manifests and
remain untouched; their jobs must be verified from the live Longhorn objects
before any future qualification decision.

`allowRecurringJobWhileVolumeDetached` is enabled because the two retained
PVCs are currently detached. Longhorn may temporarily attach a labeled volume
to create its snapshot/backup. This is not a blanket backup policy: only
volumes explicitly carrying the recurring-job label are selected.

Configuration alone is not protection. Each volume is `PROTECTED` only after:

1. the target is `available=true`;
2. a Longhorn backup reaches `Completed` and its volume/backup URL is recorded;
3. the backup is restored to a new temporary Longhorn volume/PVC;
4. the restored data and checksums pass without mounting the source PVC;
5. RPO and RTO are recorded.

For Agentgateway, the SQLite check is necessary but does not prove application
quiescence for a hot snapshot. If `integrity_check` or the application check
fails, pause the recurring job and use an application-native export or a
controlled quiescence procedure; do not call the raw snapshot protected.

Longhorn backup lifecycle and retention are managed by Longhorn. The S3 bucket
must not receive an independent object-retention policy that conflicts with
the Longhorn retain count.

## Immich Redis and Mastra workspace qualification

The 2026-10-20 qualification created these traceable Longhorn backups in the
existing `longhorn/` S3 prefix:

| PVC | Backup | Restore proof | Application proof |
| --- | --- | --- | --- |
| `immich/redis-data-immich-redis-master-0` | `dr-protect-20261020-immich-redis` | New Longhorn volume/PVC mounted read-only; AOF manifest, base RDB and incremental AOF validated with Redis 8.10.2; Redis loaded on an `emptyDir` copy and answered `PONG` | Redis recovery on a copy PASS; full Immich application recovery NOT TESTED |
| `mastra-sandbox/workspace-sandbox-claim-05473af3` | `dr-protect-20261020-mastra-active` | New volume/PVC mounted read-only; 410 files inventoried; source sandbox remained running | Agent/workflow recovery NOT TESTED |
| `mastra-sandbox/workspace-sandbox-claim-0de14859` | `dr-protect-20261020-mastra-suspended` | New volume/PVC mounted read-only; 408 files inventoried; suspended sandbox was not resumed | Agent/workflow recovery NOT TESTED |

The Redis and active workspace captures are crash-consistent snapshots. The
suspended workspace was detached and no agent process was running. A restored
workspace is file recovery evidence only: it does not prove Factory claim
reattachment or safe agent continuation. The temporary restore namespaces and
volumes are retained pending a separate cleanup approval.

The native recurring policy intentionally covers only explicitly labelled
volumes. Mastra workspaces rotate dynamically; attaching a permanent job to a
named PVC would leave orphaned schedules after claim rotation. Until Factory
exposes an owner-aware upstream lifecycle hook, the audit reports the current
Mastra backups/restores separately from continuous policy coverage. The
historical retained volumes remain untouched and must be qualified before any
longhorn label or remote backup is retired.

## PLT-56 — owner risk decision: Executor only

The owner explicitly **accepts the potential loss of the current contents** of
the two identified Executor volumes if a failure occurs after the global
RecurringJob is removed. This accepts the absence of **new** recurring backups
for these two volumes; it does **not** establish that their contents are
rebuildable, and it does not authorize any destructive operation.

- Current PVC `executor/data-executor-0`: Longhorn volume
  `pvc-dee0d6ef-edab-493b-bb94-56a2c98c9716`, Bound, 10 GiB,
  `longhorn-bulk`, StatefulSet scaled to zero.
- Historical Longhorn volume `pvc-c32ab0fc-51cb-47be-8f77-d1b0b592c2a1`:
  released PV, detached, robustness `unknown`, 10 GiB.

Read-only qualification found only the `default` group and backups from
`persistent-offsite-backup-default-group`; no dedicated Executor recurring
job. Volume contents have **not** been inspected and no link to Factory/Mastra
workspaces is established. Owner acceptance applies **only to these two exact
volume IDs**, not Factory/Mastra volumes, other PVCs, or any future Executor
volume. Do not change `StatefulSet.volumeClaimTemplates`, create competing
PVCs, mount/attach/recover these volumes, or remove any existing
PVC/PV/Longhorn volume, snapshot, backup object or S3 data.

**Executor HOLD is closed by explicit data-loss acceptance, not by a false
backup PASS.** The global recurring-job retirement remains blocked until
#949/#948 are admitted, reconciled and the 13 Velero/Kopia primary targets have
satisfactory completed backup evidence; the other retained Longhorn protections
must be verified live. This acceptance does not authorize a GitHub
`workflow-integrity` bypass or an immediate merge of #947.

## PLT-56 scope boundary

The former `persistent-offsite-backup-default-group` job selected the
`default` group and caused detached, released and otherwise rebuildable
volumes to be attached and backed up. It is intentionally absent from the
Kustomization. This change does not remove the explicit recurring job,
existing labels, snapshots or remote backup objects. The 19 strict audit gaps
must be classified before effective coverage is reduced: important data stays
on its current mechanism; explicit transitional Longhorn volumes stay on their
jobs; only accepted-loss/reconstructible data can move to an explicit Velero
exclusion. A later Velero/CNPG policy change may remove duplicate explicit
labels only after its own
completed-backup and restore evidence is recorded.

## Rollback

If the rollout causes unintended loss of scheduling or uncovered durable data,
restore the removed global recurring-job manifest and Kustomization reference
through GitOps (revert #947's targeted removal), then verify Argo and Longhorn
convergence. Do **not** remove the backup target, credentials, existing explicit
recurring jobs, labels, or application manifests as part of this rollback.
Do not delete the existing PVCs or Longhorn volumes. Existing external backup
objects remain an operator retention decision and must be inventoried before
any deletion.
