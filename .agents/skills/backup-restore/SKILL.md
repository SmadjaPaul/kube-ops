---
name: backup-restore
description: Audit and repair Velero/Kopia and CNPG/Barman coverage for stateful workloads.
---

# Backup and restore

Run `just backup-audit` first.
Contract: application PVC state -> Velero/Kopia; PostgreSQL -> CNPG Barman WAL + ScheduledBackup + ObjectStore; Longhorn is not backup.
A successful backup is not restore proof. Never delete/reinitialize PVCs during diagnosis.
