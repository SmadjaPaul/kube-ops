# AIOStreams SQLite backup and restore qualification

PVC: `media/aiostreams-data`
Database: `/app/data/db.sqlite`
Image observed: `ghcr.io/viren070/aiostreams:v2.37.0@sha256:bcfd8580695a50c8f464578a0e25af065f3bd17eac35ed82a733a18342ca9718`

## Contract

`BACKUP_VERIFIED` means that Velero/Kopia has a completed Backup and a
completed PodVolumeBackup for the real PVC after a controlled application
quiesce. It does not mean that a Longhorn volume or snapshot exists.

`SQLITE_VERIFIED` means the restored artifact passes `PRAGMA integrity_check`,
contains application tables and migration metadata, and can be reopened.

`RESTORE_VERIFIED` additionally requires the pinned AIOStreams image to start
against the isolated PVC with bootstrap keys delivered by the same ESO
references, and its `/api/v1/health` probe to become Ready. SQLite success
alone never sets this status.

## Approved procedure

1. Record the production Pod, Deployment, PVC, PV and image digest without
   reading Secret values.
2. Scale the single AIOStreams writer to zero and wait for the Pod to exit.
3. Mount the production PVC read-only in a temporary hardened Pod and create a
   targeted Velero/Kopia filesystem backup in the existing `default` location.
   Do not use a Longhorn snapshot as the backup proof.
4. Require the Velero Backup and every PVB to be `Completed`; retain the
   backup name, PVB UID and timestamps.
5. Restore into a new namespace and a new `longhorn-fast` PVC. Never restore to
   `media/aiostreams-data`.
6. Run the checked-in synthetic SQLite contract plus a disposable SQLite check
   over the restored file: `PRAGMA integrity_check`, table/migration query and
   `SELECT 1` reopen.
7. Create a disposable AIOStreams Deployment using the same pinned image and
   ESO remote keys by reference, without printing the Secret values. Require
   the health probe and migrations to complete.
8. Delete only the isolated namespace after all evidence is retained, scale
   production back to one replica, and verify the production Pod is Ready.

## 2026-10-26 execution record

The real qualification was started with a controlled quiesce, but the
Velero/Kopia Backup `aiostreams-kopia-20261026` remained `Queued` while the
single node processed the scheduled Matrix backup. No AIOStreams PVB was
created and no restore was attempted. The temporary source Pod and isolated
namespace were removed; the production Deployment was returned to one
replica. Therefore the truthful statuses are:

```text
BACKUP_VERIFIED=BLOCKED (Velero backup Queued; PVB count 0)
SQLITE_VERIFIED=NOT_EXECUTED
RESTORE_VERIFIED=NOT_EXECUTED
```

The production Pod was transiently `Running` but `NotReady` while the image
repeatedly attempted its startup refreshes; logs show the database initialised
with no pending migrations, followed by external anime-database fetch
timeouts. A later canonical check at `2026-10-26T10:33:25Z` confirmed the
Deployment `1/1` and the Pod `Ready=True` with restart count `0`. This recovery
is a production-health proof only; it is not a backup or restore proof. Do not
close the audit gap until a later run gets a completed PVB and an isolated
application health proof.

## Backup-audit before/after

The control audit before the drill reported `PROTECTED=52/53`, one
unverified production PVC (`media/aiostreams-data`), `RESTORE_RESIDUE_COUNT=20`
and `BACKUP_AUDIT_GAPS=21`. The final audit reported `PROTECTED=51/53`, two
unprotected production PVCs, `RESTORE_RESIDUE_COUNT=20`,
`ORPHAN_PVC_COUNT=0` and `BACKUP_AUDIT_GAPS=22`; the additional uncovered PVC
is the separately protected PLT-105 scope and was not modified. AIOStreams
therefore remains `UNPROTECTED`; the queued Velero Backup resource is retained
for investigation and was not deleted. The machine-readable comparison is
kept in `docs/operations/backup-audit-2026-10-26-summary.json`.
