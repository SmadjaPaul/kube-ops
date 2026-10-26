# Media: retire Audiobookshelf and SABnzbd

The operator explicitly authorised deleting the empty PVCs of these two services.
Removing their StatefulSets through Argo does not guarantee deletion of the PVCs.
The seven exact eligible PVCs are:

| Application | PVC |
| --- | --- |
| Audiobookshelf | config-audiobookshelf-0 |
| Audiobookshelf | metadata-audiobookshelf-0 |
| Audiobookshelf | audiobooks-audiobookshelf-0 |
| Audiobookshelf | podcasts-audiobookshelf-0 |
| SABnzbd | config-sabnzbd-0 |
| SABnzbd | nzb-backup-sabnzbd-0 |
| SABnzbd | incomplete-downloads-sabnzbd-0 |

Only these seven claims are authorised for deletion. The shared 2 TiB media-share
claim, any other PVC, PV, Longhorn volume or backup are NOT in scope.
PVC deletion may cause irreversible backing-volume deletion depending on PV
reclaim policy. No claim is deleted by the staging PR alone.

## Safe rollout

1. Inspect live consumers, current app/data paths, active backup and Jobs.
2. Validate the exact Media and Velero Kustomize diffs and CI.
3. Merge after independent review and reconcile through Argo CD.
4. Confirm apps-media Synced/Healthy and that BOTH legacy StatefulSets,
   Services, routes, Pods and Velero Schedules no longer exist.
5. Preview with: bash scripts/media-retired-pvc-cleanup.sh
   This checks canonical operator access, Argo/Velero prune and live Pod mounts.
6. Delete ONLY after preview using:
   ALLOW_EMPTY_MEDIA_PVC_DELETION=yes bash scripts/media-retired-pvc-cleanup.sh --execute
7. Verify no Pod references a target claim; verify their deletion and check
   media-share remains Bound, with Jellyfin/Decypharr/Arr unaffected.
8. Re-run runtime-smoke, backup-audit and orphan inventory and report findings.

Do not force-delete finalizers or directly delete Longhorn volumes.
Completed backups remain until their normal retention; there is no purge.

BookOrbit is still staged and is not known to replace every Audiobookshelf
feature (offline play, mobile progression, podcasts). The user approved
retiring the empty Audiobookshelf instance notwithstanding that limitation.
SABnzbd has no active NNTP provider; Decypharr/TorBox remains the target.
AudiobookRequest, Lidarr, Jellyfin, Arr, AIOStreams and media-share remain.

Authentik still declares both OIDC apps in legacy and v2 blueprints and
uses a grouped ExternalSecret with many active providers. Clean those
references only in a SECOND reviewed PR after verifying live blueprint
ownership, or removing one provider could break other Authentik apps.

Rollback before PVC deletion: re-add both Media and Velero refs in GitOps.
After PVC deletion: a fresh setup or an available completed backup is needed.

Related: https://linear.app/boule/issue/PLT-118
Related: https://linear.app/boule/issue/PLT-122
