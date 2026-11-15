# Hindsight OKE drill (PLT-303, D-2026-11-14-03)

Status: OKE side active (activation PR of PLT-303); evidence in the PLT-303 ticket.

Goal: prove that a Hindsight database on OKE survives
OKE database -> OKE R2 archive -> restore off Oracle, with identical content.
Variant of PLT-303 (mission 2026-11-15): the OKE database is created EMPTY
(initdb) and filled with synthetic test rows. Nothing is migrated from the
homelab, which stays the only holder of the real banks and is never read or
written (`source/` and the homelab R2 archive are not used).

| Path | Cluster | Use |
|---|---|---|
| `fingerprint/` | - | Component: read-only `psql` Job (TLS `verify-full`) running `fingerprint.sql`, plus `seed-a.sql` / `seed-b.sql`. |
| `oke-seed-a/` | OKE `hindsight` | Seed A: 3 banks + 1000 documents (waits for the schema the API creates). |
| `oke-backup/` | OKE `hindsight` | On-demand base backup `hindsight-db-drill-base`, after seed A. |
| `oke-seed-b/` | OKE `hindsight` | Seed B (WAL only) then the OKE fingerprint, in one Job. |
| `oke/` | OKE `hindsight` | Fingerprint alone (re-run). |
| `offsite-restore/` | homelab `hindsight-oke-drill` | Restore of `s3://homelab-backup-cnpg/oracle-a1/hindsight-db/` + fingerprint. Only below 65 C on tatouine. |
| `source/` | homelab | Not used in the empty-database drill. |

Fingerprint lines: server version, extensions, row count per public table,
`banks_md5`, `documents_md5`, `roles_md5`, `memberships_md5`, `schema_acl`,
`acl_md5`, `routine_acl_md5`, `database_acl`, table owners.

## Procedure (one PR per import, one PR per removal)

Imports go into `k8s/clusters/oracle-a1/hindsight/kustomization.yaml` (OKE) or
`k8s/applications/ai/kustomization.yaml` (homelab). Completed Jobs are not
pruned (Application `prune: false`) and no write tool is used: they stay as
drill residue (a few bytes), and the PVC and the Cluster are never touched.

1. Activation: `hindsight.yaml` in the OKE root, plus `oke-seed-a`. Wait for
   `Cluster hindsight-db` Ready, `ContinuousArchiving=True`, the `immediate`
   backup of `hindsight-db-daily` Completed, Job `hindsight-drill-seed-a` logs.
2. Import `oke-backup`; wait `Backup hindsight-db-drill-base` Completed; at
   least one object under `oracle-a1/hindsight-db/base/`.
3. Import `oke-seed-b`: logs give `seed_b_done_at` and the OKE fingerprint.
   Wait for the WAL archive (`archive_timeout` + 1 min).
4. Homelab (tatouine CPU temperature < 65 C, read by Prometheus or hwmon):
   import `offsite-restore/`; RTO = Cluster creation -> Ready; fingerprint lines
   equal to step 3 (passwords are not fingerprinted).
5. Remove the imports (`offsite-restore/`, drill Jobs, Backup). Deleting the
   drill namespace and its PVC is drill residue cleanup.

Pass criteria (all): OKE and off-Oracle fingerprints identical on every line;
OKE `LastBackupSucceeded=True`, `ContinuousArchiving=True`; objects under
`oracle-a1/hindsight-db/base/` and `.../wals/`; durations recorded; homelab
`hindsight-db` still `ContinuousArchiving=True` after the drill.
