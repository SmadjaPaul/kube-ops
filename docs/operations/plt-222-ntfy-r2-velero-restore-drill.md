# ntfy: Velero/Kopia restore from Cloudflare R2, isolated drill — PLT-222

Drill of 2026-11-15 (UTC) for PLT-222 / PLT-171 / PLT-92. Application: `ntfy`
(stateful, 1 Gi `longhorn-fast` PVC, SQLite `cache.db` and `auth.db`). Source:
Backup `velero-daily-ntfy-20261115042528` of the nominal 04:25 UTC Schedule on
the BSL `r2` (start 04:25:28Z, end 04:25:58Z, 152 of 152 items, 2
PodVolumeBackups complete, `data` 180 224 B, `tmp` 94 B). Procedure model:
`plt-221-sparkyfitness-r2-restore-drill.md`. PRs: #1495 (isolated namespace),
#1496 (first Restore), #1499 (new namespace), #1500 (corrected Restore) and the
PR that adds this file (teardown).

## Design

- Namespace mapping `ntfy` to `drill-ntfy2`, created by Git first
  (Namespace, default-deny CiliumNetworkPolicy: ingress and egress to the same
  namespace and DNS only, ExternalSecret `ntfy-runtime`). No Gateway, no
  HTTPRoute, no DNS, ClusterIP Service only.
- Restore whitelist: deployments, replicasets, pods, PVC, PV (listed only, see
  below), services, configmaps, serviceaccounts. No Secret, ExternalSecret,
  CiliumNetworkPolicy, HTTPRoute, CRD. `includeClusterResources: false`: no PV is
  restored, the production PV is untouched and the drill PVC gets a fresh PV.
- A resource modifier clears the PVC `volumeName` and the Argo tracking-id.
- The Restore carries `Prune=false` and `IgnoreExtraneous`: removing it from
  Git leaves the live CR as the record (deleting a Restore can delete its result
  files in the bucket; no S3 object is deleted by this drill).

## First attempt (FAIL, cause found)

Restore `plt222-ntfy-drill-20261115` (T0 06:26:28Z) ended `Completed`, 9 of 9
items, but created no PodVolumeRestore: the pod stayed in `Init:0/2`
(`restore-wait`) and the PVC was empty. Cause (velero v1.18.0 `restore.go`): a
pod's PodVolumeRestores are created only when both `persistentvolumes` and
`persistentvolumeclaims` are in the restore resources; my whitelist omitted
`persistentvolumes`. A `Completed` Restore is not data proof. The namespace was
replaced by `drill-ntfy2` (pruned by Argo with its drill PVC only) and the
Restore redone.

## Measurements (second attempt)

| Step | Time (UTC) | Evidence |
| --- | --- | --- |
| #1500 merged | 06:45:19 | CI green, CodeRabbit treated |
| T0 Restore `plt222-ntfy-drill-20261115b` created by Argo | 06:48:30 | RECONCILED |
| T1 PVR `data` Completed, 180 224 of 180 224 B | 06:48:57 to 06:49:02 | RUNTIME |
| PVR `tmp` Completed, 94 of 94 B | 06:49:03 to 06:49:07 | RUNTIME |
| T2 pod Ready (`restore-wait` done, `ntfy` 1/1) | about 06:49:09 | RUNTIME |
| Restore `Completed`, 9 of 9 items, 1 warning (`kube-root-ca.crt` exists) | 06:49:09 | RUNTIME |
| T4 check Job `NTFY_DRILL_CHECK=PASS` | 06:49:10 | RUNTIME |

- **RTO: 40 s** from Restore creation (T0) to the application check (T4); 3 min
  11 s more from merge to T0 (Argo polling). Cold start of the pod and volume
  included; 180 kB of data, so a lower bound.
- **RPO: data age 2 h 22 min at T0** (backup start 04:25:28Z). Structural bound:
  24 h (daily Schedule `velero-daily-ntfy`, 04:25 UTC).
- **Application check** (read-only Job, restored PVC mounted read-only):
  Velero marker file present; `GET /v1/health` `{"healthy":true}`;
  `GET /v1/stats` `{"messages":0,"messages_rate":0}`; admin account role
  `admin`; `cache.db` 61 440 B and `auth.db` 118 784 B, both with the
  `SQLite format 3` header; total 180 224 B, equal to the PodVolumeBackup
  `totalBytes`. The `bootstrap-admin` init container logged `user admin already
  exists`: the restored `auth.db` held the production admin user.
- **Limit**: no application data is compared with production beyond sizes and
  the user row: the live ntfy changes after the backup and the agent has no
  read access to its volume. `messages=0` means the instance holds no stored
  messages, so the message path is not exercised.
- **Production intact (RUNTIME)**: PVC `ntfy/ntfy-data` still Bound to
  `pvc-e754787a-…` (45 days old), `ntfy` pod unchanged, no PV, backup or S3
  object deleted.
- **Node**: Tctl 54 to 54.9 °C before, peak 68.75 °C during the restore (alert
  70 °C), 62 °C after.

## Teardown

Removed by Git: `k8s/optional/ntfy-drill`, its import in
`applications/platform`, the AppProject destination, the Restore and modifier
manifests. Argo prunes `drill-ntfy2` with the drill PVC and its Longhorn volume.
Kept: the two Restore CRs (history), the Backup and all R2 objects.

## Not covered

The Longhorn R2 backups were verified (79 Completed after the 03:17 UTC job) but
no Longhorn restore from R2 was run in this drill.
