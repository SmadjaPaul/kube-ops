# SparkyFitness CNPG on Cloudflare R2: cutover and isolated restore drill — PLT-221

First CNPG cluster moved from Hetzner Object Storage to Cloudflare R2 (epic
PLT-219, runbook homelab-infra `docs/operations/r2-migration.md`, step 5), and
the first isolated restore from R2, on 2026-11-12. Pilot cluster:
`wellness/sparkyfitness-db`. PRs: #1290 (archive to R2), #1293 (first base
backup, AppProject destination), #1295 (drill), and the PR that adds this file
(teardown). Drill procedure: `plt-202-matrix-mas-restore-drill.md`.

## Cutover

- CNPG accepts a single WAL archiver per Cluster: `spec.plugins` and the
  weekly `ScheduledBackup` now point to `sparkyfitness-r2-store`
  (`s3://homelab-backup-cnpg/sparkyfitness`, server `sparkyfitness-db`,
  retention 14 days). `sparkyfitness-hetzner-store` stays declared as the
  rollback target; nothing was deleted on Hetzner. Hetzner held no base backup
  for this cluster (no `Backup`, empty recovery window), so the cutover
  removed no recovery point.
- Identity: the R2 writer limited to `homelab-backup-cnpg`, through ESO from
  Doppler `cluster/prd`. The endpoint comes from `R2_S3_ENDPOINT` as
  `AWS_ENDPOINT_URL_S3`, so the account id stays out of this public
  repository. plugin-barman-cloud v0.11.0 ships boto3 1.42.37, so the sidecar
  sets `AWS_REQUEST_CHECKSUM_CALCULATION` and
  `AWS_RESPONSE_CHECKSUM_VALIDATION` to `when_required`.
- The sidecar change restarted the single instance once (about 25 s to
  `Ready`).

## Measurements

All times UTC, 2026-11-12. Evidence levels follow `acceptance-levels.md`.

| Step | Time | Evidence |
| --- | --- | --- |
| #1290 merged (`e74bb81`) | 19:52:55 | CI green, CodeRabbit treated |
| Production `Ready`, first WAL `…68` archived to R2 | 19:53:57 – 19:54:05 | RECONCILED, RUNTIME |
| #1293 base backup `20261112T200535` completed (WAL `…6B`) | 20:05:35 – 20:05:45 | RUNTIME |
| Last production segment `…6C` archived | 20:10:46 | RUNTIME |
| #1295 merged (`dbdb85c`) | 20:19:48 | CI green, CodeRabbit treated |
| Drill `Cluster` created by Argo | 20:22:03 | RECONCILED |
| `full-recovery` Job completed | about 20:22:55 | RUNTIME |
| Drill `Cluster` `Ready`, timeline 2 | 20:23:10 | RUNTIME |
| Control Job completed | about 20:23:15 | RUNTIME |

- **RTO: 3 min 22 s** from merge to `Ready`, of which about 2 min 15 s is
  Argo polling before the drill objects were created and 67 s is the restore
  itself (base backup plus one WAL segment, 18 MB database).
- **RPO: no archived write lost; structural bound 5 min.** Recovery replayed
  through `00000001000000000000006C`, the last segment production had
  archived; production produced no newer segment before recovery ended (the
  idle database switches segments only when WAL is written, at most every
  `archive_timeout` = 5 min). Under write load the loss window is the
  unarchived part of the current segment, at most 5 minutes, while archiving
  keeps pace. Completed segments not yet uploaded to R2 (archive lag or failed
  uploads, visible as `ContinuousArchiving=False`) extend the loss window.
- **Control query** (read-only transaction, counts and `max()` only):
  `in_recovery=false`, 138 user tables, `user=1`, `session=5`,
  `water_intake_entries=15`, `food_entries=4`, newest application timestamp
  2026-11-10 15:58:19Z (`water_intake.updated_at`), database 18.6 MB.
- **Production intact (RUNTIME):** `sparkyfitness-db` stayed on timeline 1,
  `Ready`, `ContinuousArchiving` and `LastBackupSucceeded` true; its archiver
  log since the cutover holds no error, no `00000002*` segment and no
  `.history` file; R2 recovery window unchanged (first point 20:05:45Z). The
  drill pod ran PostgreSQL only, without a Barman sidecar.
- **Write refusal:** the drill used the R2 `restore-ro` identity. PLT-220
  tested it on this bucket: get allowed; put, delete and listing of another
  bucket refused with 403.

## Limits and follow-up

- The base backup was only minutes old: this RTO is a lower bound. A restore
  just before the weekly base backup replays up to 7 days of WAL.
- Bucket Lock on `sparkyfitness/sparkyfitness-db/wals/` (runbook, Bucket
  Locks) is a homelab-infra change, not part of this drill.
- The other CNPG clusters move one by one with the same pattern, each with its
  own isolated drill; see PLT-221.

## Next clusters

### romm/romm-postgresql — PLT-228 (#1303, #1305, #1306, teardown)

- Cutover merged 20:55:20Z. **Unplanned outage of about 4 min** (`Ready=False`
  20:56:57Z to 21:00:56Z): during shutdown, the old instance tried to archive
  segment `…0370` with the new R2 configuration, but its sidecar still had
  the Hetzner environment (no `AWS_ENDPOINT_URL_S3`), so `barman-cloud-wal-archive`
  failed (exit 4) until the smart shutdown timeout. The new instance archived
  the segment to R2 at 21:00:48Z; no WAL was lost. The pilot had no pending
  segment at shutdown, which hid this.
- Window without an R2 recovery point: 20:56:57Z to 21:06:54Z (9 min 57 s,
  base `20261112T210645`). Hetzner stays restorable up to segment `…036F`.
- Drill: merge 21:15:39Z, `Cluster` created 21:18:13Z, `Ready` timeline 2 at
  21:19:20Z. **RTO 3 min 41 s** (67 s of restore). **RPO: no archived write
  lost** (replayed through `…0374`, last segment archived by production at
  21:11:56Z; none newer before recovery ended).
- Control query: `in_recovery=false`, 29 tables, `users=1`, `roms=22`,
  `play_sessions=12`, `saves=8`, database 11.5 MB. Production stayed on
  timeline 1, `Ready`, `ContinuousArchiving` true, no archiver error after the
  restart; the drill pod ran PostgreSQL only.

### pinepods/pinepods-db — PLT-221 (#1309, #1312, #1314, teardown)

- Cutover merged 22:01:23Z, outside 19:00–23:00 Paris. Planned outage
  accepted by the coordinator: `Ready=False` 22:02:49Z to 22:07:09Z
  (4 min 20 s), same smart-shutdown cause as romm. First R2 segment
  `…0A39` at 22:07:01Z.
- Window without an R2 recovery point: 22:02:49Z to 22:10:50Z (8 min 1 s,
  base `20261112T221042`).
- Drill: merge 22:26:09Z, `Cluster` created 22:28:10Z, `Ready` timeline 2 at
  22:29:14Z. **RTO 3 min 5 s** (64 s of restore, 20Gi volume for about 2.5 GB
  used on a 60Gi production volume).
- **RPO: about 3 min assuming no archive lag (switch time of `…0A3D` not
  measured independently).** Recovery replayed
  through `…0A3C`, archived 22:15:51Z. Production archived the next segment,
  `…0A3D`, at 22:30:51Z, after recovery ended at about 22:29:00Z. With
  `archive_timeout` at 5 min and no archive lag (the archiver logged no
  error), the first unarchived write was at the earliest 22:25:51Z; the
  archive time of `…0A3D` is an upper bound of its switch time, so archive lag
  would widen this window. `pg_last_xact_replay_timestamp()` returned null: no transaction
  was replayed after the base backup.
- Control query: `in_recovery=false`, 42 tables, `Users=2`, `Playlists=13`,
  `schema_migrations=57`, database 10.7 MB. Production stayed on timeline 1,
  `Ready`, `ContinuousArchiving` true, no archiver error since the restart;
  the drill pod ran PostgreSQL only.

### vikunja/vikunja-postgresql — PLT-221 / PLT-170 (#1323, #1325, #1326, #1330, teardown)

- Rollback base on Hetzner `20261112T2309*` completed 23:09:29Z, before the
  cutover. Cutover merged 23:13:17Z; `Ready=False` 23:14:47Z to 23:18:22Z
  (**3 min 35 s**), smart shutdown as for romm and pinepods.
- The `Backup` CR of the Hetzner pre-cutover base was recreated when the pod
  restarted and ran again at 23:18:38Z (`20261112T231838`, WAL `…0110`). That
  WAL went to R2: this second Hetzner base is **not restorable from Hetzner
  alone**. A Hetzner rollback must target the 23:09 base explicitly, never
  "latest". The last segment archived to Hetzner before the cutover was not
  recorded, so do not set a `recovery_target_time` after 23:09: recover from
  the 23:09 base with no target (replay to the end of the Hetzner WAL), after
  checking that the Hetzner WAL sequence from that base has no gap. The manifest is removed in this PR; deleting the
  CR does not delete objects. Same pattern on authentik (#1337).
- Window without an R2 recovery point: 23:14:47Z to 23:24:04Z (**9 min
  17 s**, base `20261112T232357`).
- Drill: merge 23:31:21Z, `Cluster` created 23:34:32Z, `Ready` timeline 2 at
  23:35:46Z. **RTO 4 min 25 s** (about 74 s of restore after creation).
- RPO: not measured segment by segment. Last production segment seen archived
  before the drill: `…0113` at 23:29:05Z; the drill promoted on timeline 2
  (first checkpoint REDO `…020000000100000016`). `pg_last_xact_replay_timestamp()` null: no
  transaction replayed after the base backup (idle database).
- Control job: `in_recovery=false`, 42 tables, `projects=11`,
  `task_positions=240`, latest `tasks.updated` 2026-11-06 09:25:22, database
  11.5 MB. Production stayed on timeline 1, `Ready`, `ContinuousArchiving`
  true; the drill pod ran PostgreSQL only.

### auth/authentik-postgresql-restored — PLT-221 (#1328, #1332, #1337, #1342, #1343, teardown)

- Rollback base on Hetzner `20261112T2329*` completed 23:29:29Z (WAL
  `…2100000063`). Cutover merged 23:38:12Z (00:38 Paris, night window);
  database `Ready=False` 23:41:29Z to 23:45:55Z (**4 min 26 s**). The
  authentik server failed its liveness probe once and restarted; the worker
  logged database errors only between 23:43Z and 23:45:36Z.
- Same pre-cutover `Backup` CR re-run as on vikunja: `20261112T234612` (WAL
  `…68`, archived to R2) is not restorable from Hetzner alone. Manifest
  removed in #1337. Hetzner rollback: the 23:29 base with no recovery target.
- Window without an R2 recovery point: 23:41:29Z to 00:05:48Z (**24 min
  19 s**, base `20261113T000509`, WAL `…6D`): the ScheduledBackup is weekly and
  the on-demand R2 base was merged after the cutover.
- SSO after the cutover (RUNTIME, 00:08Z): OIDC discovery 200, flow executor
  `default-authentication-flow` served the identification stage (session
  created in the database), outpost API calls 200. No complete end-user
  login was observed in the night window.
- Drill: merge 00:19:44Z, `Cluster` created 00:21:50Z, `Ready`
  timeline 2 at 00:23:00Z. **RTO 3 min 16 s** (about 70 s of restore).
- Control job: `in_recovery=false`, 230 tables, database 145 MB,
  `authentik_core_user=7` (6 active), 49 applications, 50 OAuth2 providers,
  latest event 2026-11-12 22:49:14Z. Recovery promoted on timeline 2 at
  `…2100000073` after production archived `…70` at 00:20:49Z. Production
  stayed on timeline 1, `Ready`, `ContinuousArchiving` true, no archiver
  error; the drill pod ran PostgreSQL only.

### Precondition for the remaining cutovers

Before switching `barmanObjectName`, a separate PR adds the R2 environment
(`AWS_ENDPOINT_URL_S3` from the R2 Secret, and the two checksum variables) to
the `instanceSidecarConfiguration.env` of the cluster's current Hetzner
`ObjectStore`, then waits for the rolling restart and for an `Archived WAL
file` log line of the new sidecar to Hetzner, timestamped after the restart
(`ContinuousArchiving=True` alone can predate the rollout; an idle database
may need to wait for its next segment, no forced `pg_switch_wal()` from an
agent). Hetzner keeps working because its explicit `endpointURL` is passed
as `--endpoint-url`, which wins over the environment. At the cutover the old
sidecar can then archive its last segment to R2 during shutdown. Otherwise,
plan for a smart-shutdown wait of up to 3 minutes.

## immich/immich-postgresql (PLT-243, 2026-11-13)

PRs: #1356 (R2 store declared, Hetzner sidecar prepared, pre-cutover base),
#1358 (pre-cutover base retried), #1359 (cutover), #1361 (on-demand R2 base
and drill destination), #1362 (drill), this PR (teardown).

- Precondition (#1356): the Hetzner store sidecar got `AWS_ENDPOINT_URL_S3`
  (R2 Secret), the checksum variables and `AWS_DEFAULT_REGION=us-east-1`
  (R2 rejects `fsn1`). The operator recreated the pod by itself (Ready
  15:25:26Z, under 30 s); WAL `…02B5` was then archived to Hetzner at
  15:30:17Z with that environment: **Hetzner accepts `us-east-1`**.
- The first pre-cutover Backup failed (15:24:58Z) because it ran while the
  operator recreated the pod: never merge a sidecar change and a Backup in
  the same PR. Retried as `…-20261113-b`, Hetzner base `20261113T153727`.
  It is the Hetzner rollback point (backupID, never `latest`).
- Cutover (#1359, merge 15:43:19Z): the old pod stopped at 15:44:51Z, the new
  one was created at 15:47:47Z and Ready at 15:48:14Z: **outage about
  3 min 23 s**. The precondition did not shorten it. The old pod's logs are
  gone, so the cause (failed final archive or smart shutdown waiting for the
  Immich client connections) is not proven. First WAL on R2: `…02BA` at
  15:48:31Z.
- Known anomaly reproduced: the `gap-remediation-20261019` Backup CR, pinned
  by `tests/harness/cnpg-gap-backup-contract-test.sh`, ran again after the
  restart to Hetzner (`20261113T154828`) while WAL already went to R2. That
  base cannot be restored from Hetzner alone; do not use it for a rollback.
- R2 base `20261113T155503` (WAL `…02BF`) completed at 15:55:29Z. Window
  without an R2 recovery point: **about 10 min 38 s**.
- Drill: merge 16:03:12Z, `Cluster` created 16:07:55Z, `Ready` timeline 2 at
  16:09:09Z. **RTO 5 min 57 s from the merge, 1 min 14 s of restore.**
- Control job: `in_recovery=false`, 66 tables, database 135 MB, `user=2`,
  `asset=1019`, latest `asset.createdAt` 2026-11-04 16:32Z. Production had
  archived `…02C1` (16:00:33Z) as its last segment before the drill; the
  drill promoted on timeline 2 (current segment `…0200000002000000C4`), which
  is consistent with a replay up to `…C1` (inferred: the recovery job logs
  were not kept). Production stayed on timeline 1, `Ready`,
  `ContinuousArchiving` and `LastBackupSucceeded` true; the drill had no
  Barman sidecar.

## paperless/paperless-postgresql (PLT-244, 2026-11-13)

PRs: #1365 (R2 store declared, Hetzner sidecar prepared), #1367 (restart),
#1368 (pre-cutover base), #1369 (cutover), #1370 (on-demand R2 base and
drill destination), #1371 (drill), this PR (teardown).

- Unlike immich, the operator did not recreate the pod after #1365 (the
  Hetzner store had no `instanceSidecarConfiguration` before). `paperless`
  is outside the `kubectl-rw.sh` scope, so the restart went through Git:
  `kubectl.kubernetes.io/restartedAt` on the Cluster (#1367).
- **That plain restart cut the database for 3 min 9 s** (16:43:33Z to
  16:46:42Z): the outage of about 3 minutes is the smart-shutdown wait for
  client connections, not a failed final archive. The sidecar precondition
  therefore does not shorten it; only a fast shutdown or a planned window
  would. WAL `…1F00000010` was archived to Hetzner at 16:51:33Z with the
  `us-east-1` environment.
- Hetzner rollback point: base `20261113T165722` (backupID, never `latest`).
- Cutover (#1369): stop at 17:05:36Z, `Ready` at 17:08:59Z, **outage
  3 min 23 s**. First WAL on R2: `…1F00000016` at 17:13:51Z.
- R2 base `20261113T172103` (end WAL `…19`) completed at 17:21:13Z. Window
  without an R2 recovery point: **15 min 37 s**.
- Drill: merge 17:28:34Z, `Cluster` created 17:34:14Z, `Ready` timeline 2 at
  17:35:21Z. **RTO 6 min 47 s from the merge, 1 min 7 s of restore.**
- Control job: `in_recovery=false`, 74 tables, database 20 MB, `auth_user=2`,
  `documents_document=14`, latest document added 2026-10-03 22:40Z. Production
  had archived `…1A` (17:26:14Z) before the drill; the drill promoted on
  timeline 2 (current segment `…0200001F0000001D`). Production stayed on
  timeline 1, `Ready`, `ContinuousArchiving` and `LastBackupSucceeded` true.
