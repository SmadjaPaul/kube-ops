# Backup-audit consolidation — 2026-10-19

This record consolidates the already completed DR proof and the bounded live
`backup-audit` run. It does not authorize deletion, PVC changes, or a new
restore drill.

## Live result

The audit collected all required APIs successfully in parallel and emitted a
machine-readable v2 report. The current result is:

| Signal | Result |
|---|---:|
| Production PVCs | 55 total, 52 covered, 1 unverified, 2 without a configured backup mechanism |
| CNPG backup configuration | 12/12 PASS |
| CNPG restore proof | PASS from explicit synthetic evidence |
| Restore drill status | PASS from explicit Velero/Kopia and CNPG/Barman evidence |
| Historical restore PVC residue | 17, all retained for review |
| Collection status | COMPLETE |

The three current production gaps are deliberately not collapsed into PASS:

| Namespace/PVC | UID | Classification | Finding |
|---|---|---|---|
| `immich/redis-data-immich-redis-master-0` | `a09c12b9-203b-4610-8558-1e6f8088c18c` | PROTECT | Velero schedule/backup exists, but no completed PVB or Longhorn remote backup was correlated; queues/AOF remain a separate recovery policy |
| `mastra-sandbox/workspace-sandbox-claim-05473af3` | `c36eea64-f347-46af-88a2-46ab620575b0` | UNKNOWN_REVIEW | Bound dynamic sandbox workspace, no schedule or off-site backup proof; do not label rebuildable without an explicit owner decision |
| `mastra-sandbox/workspace-sandbox-claim-0de14859` | `06fc6da9-bf5d-4538-b8a3-42fc735956c0` | UNKNOWN_REVIEW | Same finding as the other dynamic sandbox claim |

The second sandbox UID above is intentionally retained as observed in the
live report; it must be re-read before any future action. No deletion is
authorized by this record.

The four previously qualified Longhorn volumes are no longer reported as
unprotected merely because Velero has no PVB for them:

| PVC | Off-site mechanism | Restore proof |
|---|---|---|
| `agentgateway/agentgateway-state` | Longhorn S3 Completed | PASS, exact PVC UID evidence |
| `atlantis-system/atlantis-pilot-data` | Longhorn S3 Completed | PASS, exact PVC UID evidence |
| `listmonk/listmonk-uploads` | Longhorn S3 Completed | PASS, exact PVC UID evidence |
| `twenty/twenty-storage` | Longhorn S3 Completed | PASS, exact PVC UID evidence |

`offsiteBackupVerified` and `restoreVerified` remain separate fields. A
completed remote backup without an exact restore record is not a restore PASS.

## Historical PVCs

The exact 17-object inventory, namespace UIDs and PVC UIDs remain in
[`dr-synth-historical-review-manifest-2026-10-19.json`](dr-synth-historical-review-manifest-2026-10-19.json).
All 17 are `UNKNOWN_REVIEW`/`KEEP_RETENTION` candidates, not
`SAFE_TO_DELETE`: seven were Bound, ten Pending, active drill workloads and/or
Argo references were observed, and no new deletion approval exists.

## Audit contract

`scripts/backup-audit.sh` now:

- collects independent APIs in parallel with bounded requests;
- returns `PARTIAL` and a non-zero result on collection timeout or API error;
- correlates Velero PVBs and Longhorn backups to the PVC identity;
- exposes `backupConfigured`, `offsiteBackupVerified`, `restoreVerified`,
  `backupMechanism`, classification and decision in the report;
- accepts explicit, secret-free restore evidence without treating it as a
  production PVC proof unless namespace, name and UID match exactly;
- optionally persists the report with `BACKUP_AUDIT_REPORT_FILE`.

Local snapshots, a Schedule, a Completed Backup without a correlated PVB, and
absence of a Pod are not recovery proof.

## Remaining actions

1. Decide whether the two active sandbox workspaces are reconstructible and
   encode that decision explicitly, or protect them with an upstream backup
   mechanism.
2. Qualify an Immich Redis recovery policy; do not infer AOF recovery from the
   PostgreSQL or media backup.
3. Keep the 17 historical PVCs unchanged until ownership and operator intent
   are resolved individually.
