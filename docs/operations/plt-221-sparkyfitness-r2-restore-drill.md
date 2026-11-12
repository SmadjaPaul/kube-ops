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
  unarchived part of the current segment, at most 5 minutes.
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
