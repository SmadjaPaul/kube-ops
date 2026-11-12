# Matrix MAS isolated CNPG restore drill — PLT-202

Result of the first isolated restore of the production Matrix MAS database
(`matrix/matrix-mas-postgresql-clean`) from its Barman object store, on
2026-11-12. Parent ticket: PLT-145. The drill was deployed by kube-ops #1284,
its control query by #1285, and removed by the PR that adds this file.

## Scope and safety model

- Source: `s3://smadja-dev-homelab-backups/cnpg/matrix-mas-clean`, server
  `matrix-mas-postgresql-clean` (Hetzner Object Storage, `fsn1`).
- Target: namespace `matrix-mas-drill`, cluster `matrix-mas-clean-restore`,
  `bootstrap.recovery` without `recoveryTarget` (replay every archived WAL,
  then promote), 1 instance, `longhorn-bulk` PVCs (disposable).
- The drill reused the production backup key, which can write. The read-only
  guarantee was configuration, enforced in CI by
  `scripts/restore-drill-readonly-contract.sh` (called from
  `scripts/backup-static-contract.sh`): no `spec.plugins` WAL archiver, no
  `spec.backup`, no `spec.replica`, no `cnpg.io/skipEmptyWalArchiveCheck`, no
  `Backup`/`ScheduledBackup`/Velero object, no exposure object, and an
  ObjectStore without `retentionPolicy` or `serverName`. The CNPG empty-WAL
  archive check stayed enabled as a second safety net.
- Network: CiliumNetworkPolicy limited to DNS, kube-apiserver, intra-namespace
  and the Hetzner endpoint. The clusterwide audit allow-all CCNP still applies
  to every namespace (open CodeRabbit point, lane G).
- Production was never written: no `kubectl` mutation, no Secret read, the
  restored database was queried in a read-only transaction by a Job.

## Procedure (reusable)

1. Baseline, read-only: production `Cluster` conditions (`Ready`,
   `ContinuousArchiving`, `LastBackupSucceeded`), `ObjectStore` recovery
   window, and a names-only listing of the production prefix (no timeline 2
   segment, no `.history` file).
2. Add the drill root under `k8s/optional/<name>-drill`, wire it in the Argo
   application kustomization and in the AppProject destinations, and list it
   in `active_drill_roots` of `scripts/restore-drill-readonly-contract.sh`.
3. Merge after CI and CodeRabbit. The AppProject change reconciles through the
   `root` application; until then the application sync fails with
   `namespace ... is not permitted in project`.
4. Follow the `full-recovery` Job until the cluster is `Ready`. Capture the
   recovery pod logs while the Job runs: CNPG deletes the pod once recovery
   completes, and its `last completed transaction` line with it.
5. Run the control Job (row counts and `max()` of every `timestamptz`
   column, plus current WAL file) and read its logs.
6. Re-list the production prefix: only timeline 1 segments written by the
   production archiver may appear after the drill start.
7. Remove the drill by PR (cluster, namespace, disposable PVCs, contract root),
   then the AppProject destination by a second PR once Argo has pruned.

## Measurements

All times UTC, 2026-11-12. Evidence levels follow
`docs/operations/acceptance-levels.md`.

| Step | Time | Evidence |
| --- | --- | --- |
| #1284 merged (`8b59c94`) | 18:41:52 | CI: v1-contract, docs-required, workflow-integrity, CodeRabbit green |
| `apps-platform` sync blocked: namespace not yet in AppProject | 18:43:20 | RECONCILED |
| `root` reconciled the AppProject, drill `Cluster` created | 18:46:12 | RECONCILED |
| `full-recovery` Job: base `20261108T040001` + WAL replay from `0x2_53` | 18:46:48 to 19:10:48 | RUNTIME |
| Drill `Cluster` `Ready`, timeline 2 | 19:11:14 | RUNTIME |
| Control Job (#1285, `21d0bf3`) completed | 19:17:5x | RUNTIME |

- **RTO: 29 min 22 s** from merge to `Ready`. Of this, about 4 min 20 s is
  the Argo AppProject gating (avoidable by merging the AppProject destination
  first) and 24 min is WAL replay of about 1 090 segments (4.5 days of WAL)
  at about 45 to 50 segments per minute.
- **RPO, by WAL position: about 2 min 19 s at recovery end, at most about
  5 min structural.** Recovery replayed through the last archived segment,
  `000000010000000600000092` (archived 19:08:29); the next one, `…93`, was
  archived at 19:13:29, after recovery ended at 19:10:48. Timeline 2 starts
  after `…92` (control checkpoint `redo_wal_file=000000020000000600000095`
  after segment switches). Production writes not yet in an archived segment
  are the loss window: 2 min 19 s at recovery end, bounded by the production
  `archive_timeout` of 5 minutes (segments `…8D` 18:43:28 through `…94`
  19:18:29). The newest application timestamp in the restored database,
  19:07:34 (`queue_workers.last_seen_at`), is consistent with replay through
  `…92` but is not a commit timestamp; the exact last replayed commit time
  was in the recovery pod log, deleted by CNPG before capture.
- **Control query** (read-only transaction, counts only):
  `in_recovery=false`, 34 public tables, 167 `_sqlx_migrations` rows,
  `queue_jobs=3085`, `queue_schedules=20`, `oauth2_clients=1`,
  `upstream_oauth_providers=1`, `upstream_oauth_links=1`, `users=0`, database
  size 11.4 MiB. These counts were not compared with production (no
  read-only query path to the production database); `users=0` is a follow-up
  for PLT-145, not a conclusion of this drill.
- **Production intact (RUNTIME):** before, during and after the drill the
  production prefix held only timeline 1 segments (none `00000002*`, no
  `.history`), every new object being the production archiver's 5-minute
  segment. Production `Cluster`: `Ready`, `ContinuousArchiving`,
  `LastBackupSucceeded` true throughout; recovery window unchanged (first
  point 2026-11-05T16:09:31Z, last base backup 2026-11-08T04:00:09Z).
- The drill `Cluster` reports `ContinuousArchiving=True` although it has no
  archiver: without `spec.plugins` the CNPG archive command is a no-op that
  succeeds. The condition is not evidence; the prefix listing is.

## Limits

- Single-node cluster: the drill shares the node, the Longhorn disks and the
  CPU with production. Replay cost about 50 WAL segments per minute.
- RTO covers a restore into a fresh namespace from a 4-day-old base backup.
  A restore right after Sunday's weekly base backup is shorter; a restore just
  before it is longer (up to 7 days of WAL).
- The drill proves restorability of the Hetzner copy only. The R2 migration
  needs its own drill once CNPG archives to R2.
- Switchover (pointing MAS to a restored cluster) was not executed; see the
  PLT-145 procedure draft.
