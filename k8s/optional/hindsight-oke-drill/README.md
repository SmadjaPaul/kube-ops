# Hindsight OKE drill (PLT-301, D-2026-11-14-03)

Status: prepared, NOT imported by any root. Evidence: none yet (`NOT_TESTED`).

Goal: prove that the Hindsight data survives
homelab R2 archive → OKE recovery → OKE R2 archive → restore off Oracle,
with identical banks and roles. The homelab source is only read.

| Path | Cluster | Use |
|---|---|---|
| `fingerprint/` | — | Component: read-only `psql` Job (TLS `verify-full`) running `fingerprint.sql`. |
| `source/` | homelab `hindsight-personal` | Fingerprint of the source. |
| `oke/` | OKE `hindsight` | Fingerprint of the OKE recovery. |
| `offsite-restore/` | homelab `hindsight-oke-drill` | Restore of `s3://homelab-backup-cnpg/oracle-a1/hindsight-db/` + fingerprint. |

Fingerprint lines: server version, extensions, row count per public table,
`banks_md5` (all columns of every bank), `roles_md5` (privilege attributes),
`memberships_md5`, `acl_md5` (table ACLs, PUBLIC and grant options included), table owners.

## Procedure (one PR per import, one PR per removal)

Writes window: the homelab Hindsight API has no known writer today. Record
the source fingerprint right before step 2; if any line differs later, check
writes after the recovery end time before concluding `FAIL`.

1. Import `source/` into `k8s/applications/ai/kustomization.yaml`. Read
   `bash scripts/kubectl-ro.sh logs -n hindsight-personal job/hindsight-fingerprint`.
   Remove the import, then delete the completed Job (reconstructible).
2. OKE: add `hindsight.yaml` to `k8s/clusters/oracle-a1/apps/kustomization.yaml`
   and `../../../optional/hindsight-oke-drill/oke` to
   `k8s/clusters/oracle-a1/hindsight/kustomization.yaml`. Wait for
   `Cluster hindsight-db` Ready, `ContinuousArchiving=True`, and the
   `immediate` backup of `hindsight-db-daily` Completed. Measure the recovery
   duration (Cluster creation → Ready).
3. Compare the OKE fingerprint with step 1: every line equal.
4. Import `offsite-restore/` into `k8s/applications/ai/kustomization.yaml`.
   Wait for `hindsight-db-offsite` Ready; compare its fingerprint: every line
   equal to step 3.
5. Remove the `offsite-restore/` import. Deleting the drill namespace and its
   PVC is a drill residue cleanup (allowed: residues of drills).

Pass criteria (all): 3 fingerprints identical on every line (passwords are
not fingerprinted: the off-Oracle restore uses a CNPG-generated password); OKE `LastBackupSucceeded=True`;
objects present under `oracle-a1/hindsight-db/base/` and `.../wals/`; recovery
and off-Oracle restore durations recorded; homelab `hindsight-db` still
`ContinuousArchiving=True` after the drill.
