# Backup-audit recovery policy — 2026-10-20

This record qualifies the three live production gaps exposed by the bounded
`backup-audit` after #571. It does not mutate PVCs, interrupt sandboxes, or
authorize a cleanup.

## Decisions

| PVC | UID | Policy | Current status | Evidence |
|---|---|---|---|---|
| `immich/redis-data-immich-redis-master-0` | `a09c12b9-203b-4610-8558-1e6f8088c18c` | `PROTECT_OFFSITE` | `UNPROTECTED` | Redis is used by both Immich server and machine-learning workloads; AOF is enabled and RDB snapshots are disabled. No completed off-site backup was correlated. |
| `mastra-sandbox/workspace-sandbox-claim-05473af3` | `c36eea64-f347-46af-88a2-46ab620575b0` | `UNKNOWN_REVIEW` | `UNKNOWN_REVIEW` | Bound `longhorn-fast` workspace; its active pod is Ready, but `/workspace` is not a Git checkout and contains files. No off-site proof or safe loss/recovery test exists. |
| `mastra-sandbox/workspace-sandbox-claim-0de14859` | `06fc6da9-bf5d-4538-b8a3-42fc735956c0` | `UNKNOWN_REVIEW` | `UNKNOWN_REVIEW` | Claim and Sandbox are suspended, the volume is detached, and no pod exists to inspect without resuming the sandbox. No off-site proof exists. |

The exact records are in
[`pvc-recovery-policy-2026-10-20.json`](pvc-recovery-policy-2026-10-20.json).
They are matched by namespace, name, and UID. If a PVC is recreated, the old
decision is intentionally ignored and the new object returns to an unsafe
status until requalified.

## Mastra workspace contract

The durable contract remains:

- GitHub commit and push are the durable code boundary;
- Factory/Mastra storage is the durable task/session boundary;
- a SandboxClaim and its Longhorn workspace are replaceable execution state;
- OTEL traces are observability, not a checkpoint or filesystem backup.

Factory's recovery guard requires proof that the session has no active or
pending work and no persisted filesystem/tool activity before it permits
recreation after claim loss. The existing Factory tests cover persisted files,
tool activity, restart reattach, and refusal of unproven recovery. This audit
did not stop or resume either live sandbox, so it cannot demonstrate the
`EPHEMERAL_VERIFIED` transition. Both workspaces remain `UNKNOWN_REVIEW`.

The active sandbox was observed with one attached healthy Longhorn volume
(`pvc-c36eea64-f347-46af-88a2-46ab620575b0`) and a Ready pod. A read-only
inspection found no `/workspace/.git`, 410 files, and approximately 3714 KiB.
This is evidence that the workspace is not proven to be an empty cache; it is
not a claim that its file contents are durable application state.

## Immich Redis policy

The Redis StatefulSet is a single replica on `longhorn-fast`, with
`appendonly yes` and `save ""`. Immich's server and machine-learning workloads
refer to it. A loss would at least lose queued/in-flight work and any Redis
state not represented in PostgreSQL; the repository contains no production
failure exercise proving that every such state is safely recreated. The
correct decision is therefore `PROTECT_OFFSITE`, not an accepted-loss or
rebuildable exemption. The source volume was not modified.

## Current audit result

The live collection completed in approximately six seconds:

```text
PRODUCTION_PVC_COVERAGE=FAIL (52/55)
PRODUCTION_RECOVERY_STATUS=FAIL (PROTECTED=52 EPHEMERAL_VERIFIED=0 EXCLUDE_ACCEPTED_LOSS=0 UNKNOWN_REVIEW=2 UNPROTECTED=1)
CNPG_BACKUP_CONFIGURATION=PASS (12/12)
CNPG_RESTORE_PROOF=PASS
RESTORE_DRILL_SUCCESS=PASS
RESTORE_RESIDUE_COUNT=17
```

The 17 historical PVCs remain unchanged and are still `KEEP_RETENTION` /
`UNKNOWN_REVIEW`; this work does not turn their audit state into a deletion
decision.
