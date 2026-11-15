# paperless: full isolated restore from Cloudflare R2 (database + files + application) — PLT-171

Drill of 2026-11-15 (UTC) for PLT-171 (DR drill, ex PLT-92/PLT-51). Application:
`paperless` (paperless-ngx 3.2.1, CNPG `paperless-postgresql`, PVCs
`paperless-data` and `paperless-media`). Procedure models:
`plt-221-sparkyfitness-r2-restore-drill.md` (CNPG leg) and
`plt-222-ntfy-r2-velero-restore-drill.md` (Velero leg, with the Velero 1.18
lesson: `persistentvolumes` must be in the Restore resources, otherwise no
PodVolumeRestore is created). PRs: #1502 (island), #1503 (restore and check)
and the PR that adds this file (teardown).

## Sources

- CNPG: R2 archive `s3://homelab-backup-cnpg/paperless`, server
  `paperless-postgresql`, read with the R2 `restore-ro` identity (ExternalSecret
  `SecretSynced=True` at 07:21Z, before any restore object). Point-in-time
  target `2026-11-15 04:40:28+00`, the start of the file backup, so database
  and files describe the same instant. The R2 bases were `20261113T172103` and
  `20261115T063001`; only the first one precedes the target.
- Velero: `velero-daily-paperless-20261115044028`, BSL `r2`, `Completed`
  04:40:28Z to 04:41:09Z, 205/205 items, PodVolumeBackups `data`
  17 205 311/17 205 311 B and `media` 70 723 036/70 723 036 B.

## Island

Namespace `drill-paperless` (PSA enforce baseline for the Velero restore-wait
init container). Default-deny CiliumNetworkPolicy: same-namespace traffic and
DNS only. A second policy selects only the drill CNPG pods: CNPG operator on
8000, kube-apiserver, R2 EU S3. ClusterIP Services only; no Gateway,
HTTPRoute, DNS record, federation or callback. The drill Cluster has the
production name inside the island, so the restored Deployment finds
`paperless-postgresql-app` and `paperless-postgresql-rw` unchanged. It has no
`spec.plugins` and no backup section (`restore-drill-readonly-contract.sh`
PASS). The Restore excluded Secrets, ExternalSecrets, CiliumNetworkPolicies
and HTTPRoutes; a resource modifier cleared the PVC `volumeName`, set
`longhorn-bulk` and cleared the Argo tracking-id.

## Measurements

| Step | Time (UTC) | Evidence |
| --- | --- | --- |
| T0 window announced in PLT-171 | 07:09:12 | Linear |
| #1502 merged, island reconciled | 07:17:24, 07:21:53 | RECONCILED |
| T1 #1503 merged (restore submitted) | 07:35:03 | CI green, CodeRabbit treated |
| Cluster and Restore created by Argo | 07:38:01, 07:38:02 | RECONCILED |
| PVR `data` Completed, 17 205 311 of 17 205 311 B | 07:38:27 to 07:38:33 | RUNTIME |
| PVR `media` Completed, 70 723 036 of 70 723 036 B | 07:38:38 to 07:38:50 | RUNTIME |
| Restore `Completed`, 15/15 items, 2 warnings | 07:38:59 | RUNTIME |
| PITR redo done (338.91 s), timeline 2 | about 07:44:20 | RUNTIME (Loki) |
| T2 drill Cluster `Ready` | 07:44:39 | RUNTIME |
| Restored app answers (`/accounts/login/` 200) | 07:45:23 | RUNTIME |
| T3 SQL and file sentinels PASS | 07:45:28 | RUNTIME |
| T4 API smoke PASS (`PAPERLESS_DRILL_CHECK=PASS`) | 07:45:32 | RUNTIME |

- **RTO = T4 − T1 = 10 min 29 s** (threshold announced: 30 min, PASS). From
  object creation: 7 min 30 s; 2 min 58 s were Argo polling. Files leg: 57 s.
  Database leg: 6 min 38 s, of which 5 min 39 s of WAL redo (about 35 h of WAL
  from the 2026-11-13 base, because the target precedes the 06:30 base).
- **RPO = S_app − W0: `RPO=NOT_MEASURED`.** W0 is known: the last recovered
  commit is at 04:35:00.09Z (PostgreSQL `last completed transaction`); recovery
  stopped before the next commit (04:45:00.02Z), as the target requires. S_app,
  the last production write at the incident time, is not measured: the drill
  wrote no production sentinel and the agent has no read access to the
  production database. Data age at T1: 3 h 00 min (database), 2 h 55 min
  (files). Structural bounds: database 5 min (`archive_timeout`, when replaying
  to the latest WAL, as in PLT-221); files 24 h (daily Schedule, longer if a run
  fails). The application RPO is therefore the file bound.
- **T3, SQL and file sentinels** (check Job, restored PVCs mounted read-only,
  counts only): 14 documents; 14 originals whose SHA-256 equals the checksum
  stored in SQL, 0 missing, 0 mismatch, 0 error; 1 archive, match; sentinel
  document 14 (newest, added 2026-10-03 22:40:59Z) matches; 0 documents added
  after the file backup start. Database and files are consistent.
- **T4, application smoke**: a drill-only user created in the drill database
  (random password, never printed) read the document list through the
  restored ClusterIP Service: API count 14 = ORM count of root documents 14.
- **Ownership**: drill PVCs Bound to fresh `longhorn-bulk` PVs
  (`pvc-3f3c6d2f-…` data, `pvc-109fd9a6-…` media, `pvc-2c40f0a6-…` database).
- **Production intact (RUNTIME, 07:46Z)**: PVCs `paperless-data`,
  `paperless-media`, `paperless-postgresql-1` still Bound to their 2026-09-30
  PVs; pods unchanged (22 h); `paperless-postgresql` timeline 1, `Ready`,
  `ContinuousArchiving` and `LastBackupSucceeded` true. No backup, PVC, PV or
  S3 object deleted.
- **Node**: Tctl 56 °C before, peak 70.75 °C at 07:39:43Z (PodVolumeRestores
  plus WAL replay), 58 °C after. The 70 °C alert was reached once; no further
  load was started; the 75 °C stop was not reached.

## Limits

- 14 documents and 88 MB: a small data set, so the RTO is a lower bound.
- The recovery Job pod was gone at T2; its key lines come from Loki.
- No count was compared with production (no production read). The newest
  document dates from 2026-10-03, so the restored set very probably equals
  production, but this is not proven.
- The 2 Restore warnings were not read (no Velero CLI in the read-only
  path); the ntfy drill showed `kube-root-ca.crt` already exists.
- A `Completed` Restore is not the acceptance: the acceptance is T3 and T4.

## Teardown

Removed by Git: `k8s/optional/paperless-full-drill`, its import, the AppProject
destination, the Restore and modifier manifests, the active drill root. Argo
prunes `drill-paperless` with its drill PVCs. The three drill PVs use the
`Retain` policy and become `Released`: they are listed for the next PLT-46
batch and not deleted here. Kept: the Restore CR (`Prune=false`, record), the
Backup and all R2 objects.

`docs/operations/dr-restore-evidence-2026-11-15.json` records the drill for
`backup-audit` (`CNPG_RESTORE_PROOF=PASS`, `RESTORE_DRILL_SUCCESS=PASS`); like
the earlier evidence files it expires after 24 h (`maxAgeSeconds`).
