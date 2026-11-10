# PLT-56 — storage efficiency and cleanup handoff (2026-11-10)

This record separates declarative corrections from destructive storage
reclamation. It is a handoff for the normal branch → checks → review → Argo
path; it is not an authorization to delete a PVC, Longhorn volume, backup or
object-store object.

## Runtime evidence

The live cluster was revalidated through the canonical operator kubeconfig.

| Surface | Observation | Decision |
| --- | --- | --- |
| `media/media-share` | Bound, `longhorn-bulk`, requested 2 TiB; only the running Decypharr Pod mounts it; the one-shot layout Job is complete | Retire Decypharr and the layout Job first; retain the claim until the post-prune gate proves zero consumers |
| Media application PVCs | `aiostreams-data` 4 GiB and `polyfin-data` 20 GiB are separate claims | Keep both; classify as protected application state |
| `media-share` content | Read-only inspection reports about 120 KiB and no regular files under `/data` | Rebuildable media layout; no file backup is required, but do not infer that this alone authorizes PVC deletion |
| Backup audit | `32/42` production PVCs covered, `10` unprotected, `13/14` CNPG backup configurations, restore proof unproven | Keep the Longhorn fallback; repair primary coverage before reducing it |
| CNPG SparkyFitness | `backup.yaml` existed but was not included by the active package | Admit the existing Barman ObjectStore and ScheduledBackup declaratively |
| Polyfin | `polyfin-data` had no targeted Velero schedule | Add a dedicated daily schedule; PostgreSQL remains CNPG/Barman-owned |

The live result remains a failed backup gate until a completed Barman source,
WAL evidence and the PLT-148 primary-backup qualification are recorded. A
`Backup` or `ScheduledBackup` object alone is not restore proof.

## Declarative changes in this worktree

- SparkyFitness includes its CNPG ObjectStore and ScheduledBackup.
- A dedicated daily Velero schedule selects only the Polyfin workload; it does
  not select the reconstructible `media-share` claim.
- Decypharr and its one-shot media layout Job are no longer active GitOps
  resources. The legacy Arr↔Decypharr/Arr↔Prowlarr policies remain rendered as
  inert compatibility manifests because the repository's protected PLT-118
  contract requires them; their retirement is a separate owner-admitted change
  after the retired workload inventory is closed.
- `media-share` remains declared and explicitly classified as
  `reconstructible`/`exclude`; its deletion is a separate post-prune action.
- PVC data classes and backup contracts are checked for changed PVC manifests.
- `Homelab Storage Efficiency` records logical PVC usage, Longhorn logical vs
  actual bytes, guest disk write throughput and Prometheus ingestion. Missing
  Proxmox ZFS, SMART Data Units Written and Longhorn physical I/O metrics are
  shown as instrumentation gaps, not treated as zero.

## Cleanup gate

The next operator-approved step may delete only the exact `media/media-share`
claim after all of these are observed from the live cluster:

1. `apps-media` is Synced/Healthy on the retirement revision.
2. No Pod, Job, StatefulSet, Deployment, restore object or manifest references
   `media-share`.
3. The claim UID and PV/Longhorn identity are unchanged from the preflight;
   the claim has no active `VolumeAttachment` and the Longhorn volume is
   detached.
4. Polyfin, AIOStreams and AudiobookRequest remain Ready, and no BookOrbit
   package has been admitted in its place.
5. The owner explicitly approves the exact claim deletion. No direct Longhorn
   volume deletion, finalizer removal or object-store purge is part of this
   gate.

The existing seven-claim Audiobookshelf/SABnzbd cleanup contract remains
separate and is not expanded by this record.

## Architecture note

The public [`mitchross/talos-argocd-proxmox`](https://github.com/mitchross/talos-argocd-proxmox)
reference reinforces directory-owned Argo applications, sync-wave ordering and
backup-aware rebuilds. It does not justify replacing this homelab's Longhorn
primary plane with Proxmox CSI: the local contract keeps Longhorn primary and
uses Proxmox CSI only for compatibility/staged recovery.
