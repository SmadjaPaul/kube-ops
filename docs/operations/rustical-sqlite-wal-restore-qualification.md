# RustiCal 0.18 — SQLite/WAL restore qualification (PLT-137)

## Exact upstream contract

`ghcr.io/lennart-k/rustical:0.18.0` uses its SQLx SQLite store.
In upstream `crates/store_sqlite/src/lib.rs::create_db_pool`, connection
options explicitly set `journal_mode(Wal)`. There is therefore a
credible risk of losing committed calendar/contact changes if a backup
copies **only** the SQLite `.db` file during live writes.

Source:
https://github.com/lennart-k/rustical/blob/v0.18.0/crates/store_sqlite/src/lib.rs

## Safe static/synthetic proof (no cluster access)

```sh
python3 scripts/rustical-sqlite-wal-synthetic.py
```

The program has **no CLI paths or credentials**. It creates an isolated
temporary SQLite fixture with 2 synthetic users, a committed pre-WAL
entry and 2 committed changes while WAL has not been checkpointed.

It proves both:
- A naive copy of `*.db` alone misses at least one WAL transaction
  (negative control).
- SQLite's native **online backup API** creates a consistent DB image
  that restores with all committed rows and `PRAGMA quick_check=ok`
  (positive control).

Expected:
`RUSTICAL_WAL_SYNTHETIC=PASS`,
`RUSTICAL_K8S_PVC_RESTORE=NOT_EXECUTED`,
`RUSTICAL_VELERO_RESTORE=NOT_EXECUTED`.

Do not conflate this database-level synthetic test with an application
restore, a Velero backup, a filesystem snapshot, or data isolation proof.

## Kubernetes qualification — separate approved runtime phase

The deployed pilot `k8s/applications/platform/rustical-pilot`
**deliberately** removes the PVC and Velero Schedule and substitutes
`emptyDir`. The dormant source `k8s/optional/rustical` has
`rustical-data` PVC (Longhorn) and a daily Velero schedule.

Before production promotion:
1. Inspect the **live** RustiCal SQLite config `db_url` and storage
   path *without dumping credentials*. Do not guess database filenames.
2. Create an isolated disposable namespace/claim with uniquely named
   synthetic test fixtures. Verify persistence across application
   restart and no crosstalk between synthetic users.
3. Design a coherent snapshot protocol: native SQLite online backup
   or controlled shutdown/checkpoint before a filesystem-level backup;
   coordinate any Velero/Kopia volume backup with that protocol.
4. Test actual Velero backup and restore into a disposable target,
   restart the same pinned RustiCal version and read calendar + contact
   fixture records back through the DAV API. Include rejection of
   cross-user reads. Record per-step evidence and latency.
5. Test failure/retry and rollback; only then propose a minimal
   persistent PVC + Velero promotion PR. Avoid changing the global
   backup architecture, legacy jobs, unrelated apps or users.

Security boundaries: never touch active PVC, user secrets or shared
`rustical` data; use exact namespace-scoped manifests and restore target.
The SQLite fixture test only validates the need for a coherent
backup and one safe API—not the eventual production backup machinery.
