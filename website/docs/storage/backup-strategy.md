# Backup Strategy

The previous Longhorn-to-MinIO recurring-job strategy is retired.

The canonical backup, restore, and disaster-recovery contract is:

- [Backup, Restore, and Disaster Recovery Contract](../backup/backup-restore-contract.md)

Longhorn is runtime storage, not the offsite backup authority. PostgreSQL is protected by CloudNativePG/Barman to Hetzner Object Storage, Kubernetes resource state by resource-only Velero backups, and selected non-database PVC data by VolSync/Restic to Hetzner Storage Box.
