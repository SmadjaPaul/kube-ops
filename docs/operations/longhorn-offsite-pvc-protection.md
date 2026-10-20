# Longhorn off-site protection for retained PVCs

Status: the target is reconciled and the first restore proofs are recorded in
`dr-restore-evidence-2026-10-20.json`. The four original retained PVCs remain
covered by the existing policy. Immich Redis now has an explicit recurring
backup assignment; the two Mastra workspace PVCs are deliberately protected
by traceable one-off qualification backups until their dynamic lifecycle has a
safe owner-aware scheduling mechanism.

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

## Four PVCs

The official `persistent-offsite-backup` recurring job runs daily at 03:17 UTC,
retains seven backups per volume and allows one concurrent backup. The four
PVCs are explicitly marked as the recurring-job source:

- `agentgateway/agentgateway-state` — SQLite; snapshot/restore validation
  must run `PRAGMA integrity_check` and a read-only application-level check.
- `atlantis-system/atlantis-pilot-data` — protect the dormant pilot state;
  GitHub App readiness remains a separate blocker.
- `listmonk/listmonk-uploads` — retained, unmounted data-only PVC.
- `twenty/twenty-storage` — retained, unmounted data-only PVC.

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

The native recurring policy intentionally covers Immich Redis only. Mastra
workspaces rotate dynamically; attaching a permanent job to a named PVC would
leave orphaned schedules after claim rotation. Until Factory exposes an
owner-aware upstream lifecycle hook, the audit reports the current Mastra
backups/restores separately from continuous policy coverage.

## Rollback

Revert the PR to remove the target, ExternalSecret, recurring job and labels.
Do not delete the existing PVCs or Longhorn volumes. Existing external backup
objects remain an operator retention decision and must be inventoried before
any deletion.
