# Longhorn off-site protection for retained PVCs

Status: PR-only configuration. No Longhorn backup target or recurring backup
was enabled by this document until the GitOps change is reconciled and the
first restore proofs pass.

## Native capability and target

The installed Longhorn chart is 1.12.1. Its native `defaultBackupStore`
configuration supports an S3-compatible target, a credential Secret and a
poll interval. The target is the existing Hetzner bucket
`smadja-dev-homelab-backups`, under the `longhorn/` prefix. Velero continues
to own its existing `velero/` prefix.

ESO creates `longhorn-hetzner-credentials` in `longhorn-system` from the same
two Doppler keys already used by Velero. No credential value is stored in Git.
The endpoint is the existing non-secret Hetzner endpoint.

The cluster currently has `BackupTarget/default` with an empty URL and
`available=false`, no Longhorn `BackupVolume` or backup, and no recurring job.
The PR changes only this backup configuration; it does not change a PVC,
volume size, StorageClass, replica count or data path.

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

## Rollback

Revert the PR to remove the target, ExternalSecret, recurring job and labels.
Do not delete the existing PVCs or Longhorn volumes. Existing external backup
objects remain an operator retention decision and must be inventoried before
any deletion.
