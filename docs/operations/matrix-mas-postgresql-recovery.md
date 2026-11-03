# Matrix MAS PostgreSQL — non-destructive recovery playbook

**Incident:** PLT-60 (2026-11-04). `account.smadja.dev` HTTP 503, zero MAS
endpoints; CNPG `matrix/matrix-mas-postgresql` is NotReady and PostgreSQL 17.7
reports `PANIC: replication checkpoint has wrong magic 0 instead of 307747550`.
Synapse and Element remain reachable. An HTTP 200 from Synapse is **not**
evidence that MAS sign-in works.

## Critical boundaries

- Preserve `matrix-mas-postgresql` and its **both** PGDATA + WAL PVCs as
  immutable incident sources; never delete the cluster or overwrite these
  volumes as part of an exploratory recovery.
- Do not rotate or regenerate `matrix-generated` signing/encryption keys.
  Keep `server_name=smadja.dev`, the existing MAS/OIDC identifiers and
  user/room identities unchanged.
- Never run `pg_resetwal`, blind `pg_rewind`, `initdb` or manual replacement
  of `pg_logical/replorigin_checkpoint` **on the production PVC**.
- A failed agent run is disposable; **Matrix user data and credentials are not**.
- No production cutover until recovered data, effective RPO, client sign-in,
  signing-key continuity and a reversibility plan have been demonstrated.

## Existing declarative recovery inventory

| Asset | Git source |
| --- | --- |
| CNPG source | `k8s/applications/platform/matrix/database-mas.yaml`, single instance, PG17.7, Longhorn bulk PGDATA 10Gi + WAL 5Gi |
| Backup ObjectStore | `database-objectstores.yaml`, `matrix-mas-hetzner-store` |
| S3 historical destination | `s3://smadja-dev-homelab-backups/cnpg/matrix-mas` |
| Backup policy | `database-scheduled-backups.yaml`, weekly full + plugin-managed continuous WAL archive, retention `14d` |
| Database auth | Existing CNPG app Secret; separately from `matrix-generated` |
| App mapping | `values.yaml`: MAS -> `matrix-mas-postgresql-rw:5432` |

The latest **observed** full backup at incident time was 2026-10-25.
This is not proof that the effective recoverable RPO is 2026-10-25:
verify the actual Barman catalog and complete, contiguous WAL archive.

## Phase A — read-only triage

1. Capture exact UID, pod, restart history, events, CNPG conditions, PG image
   and failing logs without printing secrets. Compare disk fullness, PV/PVC,
   Longhorn volume health, node restart and any other contemporaneous PG
   errors across clusters.
2. Enumerate completed CNPG Backups and the `matrix-mas-hetzner-store`
   Barman backup catalog. Verify S3 credentials *availability only* and
   contiguous WAL coverage on the chosen timeline; do not expose values or
   dump object contents into Git/Linear.
3. Check whether the last complete base backup predates the first observed
   corruption, and whether replay can reach a recent target. If a target
   point cannot be proved, record `RPO=UNKNOWN`.
4. Confirm whether logical replication origins were configured (MAS normally
   does not require logical replication, but this must be verified). Do not
   infer this from the PANIC message alone.

## Phase B — isolated PITR preferred

1. Create a **new**, clearly named temporary namespace and CNPG Cluster with
   **new** PGDATA/WAL PVCs and no public Service, callback, federation,
   external HTTPRoute or application writer. Use a fresh, scoped credential
   reference. This must not appear in the normal production kustomization.
2. Use CNPG native `bootstrap.recovery` with `externalClusters[].plugin`
   `barman-cloud.cloudnative-pg.io`, referencing an ObjectStore available
   in the recovery namespace and `serverName: matrix-mas-postgresql`.
   Read historical backup + WAL from the existing S3 prefix, but **do not
   configure the clone to archive into that same serverName/prefix**.
3. Pin an actual, verified `recoveryTarget.backupID` (and optional
   `targetTime`/LSN) only after reading the live backup catalog. Restore
   to the most recent *verified* safe point. Stop if WAL is missing or
   recovery asks to overwrite the source archive.
4. Validate SQL connections, ownership, migration/table structure, row counts
   and MAS-specific persistent state. Keep this a DB-only isolated test;
   do not issue real login callbacks before the network and credentials
   are properly isolated.
5. Record the precise recovery timestamp, source backup ID, last applied WAL
   and observed data loss window. If an otherwise clean restore contains
   fewer users/sessions than expected, escalate the RPO rather than silently
   promoting it.

CloudNativePG upstream recovery guide:
https://cloudnative-pg.io/docs/devel/recovery/

## Phase C — only if PITR fails: forensic copy

PostgreSQL identifies this exact PANIC in
`pg_logical/replorigin_checkpoint` while reading logical replication origin
state (PostgreSQL `src/backend/replication/logical/origin.c`).
A third-party case documents moving the file aside, but this is **not an
official CNPG data-repair procedure** and does not prove wider data integrity.

Only after a point-in-time copy/snapshot with verifiable read-only source
preservation, test whether a stopped, *isolated clone* with no logical
replication origins can start after the **clone's** damaged file has been
backed up and moved aside. Never perform this experiment on the original.
If it starts, inspect DB integrity independently; do not treat successful
startup as proof that all data is intact.

References:
- PostgreSQL source: https://github.com/postgres/postgres/blob/master/src/backend/replication/logical/origin.c
- Case report: https://knowledge.broadcom.com/external/article/286192

## Phase D — promotion gate

A production switch requires explicit evidence of:
- Database health, schema/data integrity and effective recovery RPO;
- continuity of `matrix-generated` MAS/Synapse cryptographic material;
- successful Authentik -> MAS -> Element login and new token lifecycle;
- existing-user read access, private room history, and Factory outbound
  message compatibility (single bounded test);
- Argo/GitOps-owned reversible service cutover and no competing DB writers.

Do not promote any PITR attempt that silently loses important Matrix user
data; report the loss window and obtain a specific operator RPO decision.

**Status at writing:** analysis/preparation only. No cluster repair, PVC
snapshot, PITR restore, database mutation or MAS runtime PASS is claimed.
