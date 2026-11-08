# Arr / Seerr retirement — 2026-11-08

## Decision
The owner explicitly accepts losing ALL application data for the obsolete media acquisition/request stack. Retire **Radarr, Sonarr, Prowlarr, Bazarr, Lidarr Jellyseerr/Seerr and Jellyfin**. No migration is required for their private settings and queues.

Polyfin is the replacement direction, but it is not a reason to delete shared media infrastructure: **retain** AIOStreams, Polyfin, Decypharr, `media-share`, audiobook services/BookOrbit pilot, and Immich. RDT-Client, Sabnzbd and Recyclarr sources are already absent from the parent active media Kustomization; do not accidentally activate them.

## Declarative change in this PR
- Remove `arr`, `jellyseerr`, `jellyseerr-secrets.yaml` and `jellyfin` from `k8s/applications/media/kustomization.yaml`.
- Remove dedicated daily backup Schedules for radarr/sonarr/prowlarr/lidarr/bazarr/jellyseerr/jellyfin from the Velero Kustomization (do not modify other schedules).
- Remove dedicated Arr/Prowlarr Cilium policies from the media policies Kustomization.
- Retain the historical source manifests for audit/rollback, but exclude them from the active Kustomize graph.

## Acceptance — require observed evidence
1. `kustomize build k8s/applications/media` must not include StatefulSet/Service/HTTPRoute for the six retired apps, but must still include active Polyfin, AIOStreams, Decypharr and shared storage.
2. Render Velero and media policy overlays and show only the retired resources disappear. Confirm no other namespace or critical policy was altered.
3. Confirm Git commit SHA, CI contract checks, merge, Argo `apps-media` and relevant infrastructure app reconciliation. Verify the unwanted workloads/HTTPRoutes/Services have actually been pruned, **not merely** removed from Git.
4. In the live cluster, inventory `kubectl -n media get pvc,pv` / Longhorn objects and their owners. Delete *only* individual PVCs (including Jellyfin's actual claim names) proven to belong to the retired apps after the workload is gone. Verify data is disposable; never delete `media-share` or Polyfin/AIOStreams/Decypharr data. StatefulSet PVCs can remain after StatefulSet deletion; GitOps prune is not proof of PVC deletion.
5. Audit orphaned secrets, Doppler keys, Authentik apps/Outposts and portal bookmarks; remove only exact owners after checking no consumer. `daily-sabnzbd.yaml` is not included by the current Velero Kustomization; classify it as dormant, not an active Schedule.
6. Record resources, volumes and estimated freed resources from measured runtime metrics; never invent capacity or RAM savings. Test Polyfin and AIOStreams once more after prune. Do not delete shared libraries or BookOrbit-staged data.

**Safety:** No direct `kubectl delete -f` over a whole directory, no namespace deletion, no indiscriminate PVC/Longhorn garbage collection, no deletion of shared Doppler credentials, and no reset of unrelated databases or Factory. The removal is user-approved only for the named retired services. Keep normal GitHub protection/CI/Argo gates.

## Book stack scope
BookOrbit v3.6 is **staged only / ADMISSION_PAUSED** per `k8s/applications/media/bookorbit/README.md` and PLT-122. Its planned Decypharr→TorBox/qBittorrent integration is unproven, so do **not** retire Decypharr or `media-share` here. Audiobookshelf already retired, but `audiobookrequest` is still active and not included in deletion approval. Jellyfin OIDC (Authenticator blueprints, secrets and portal) must be assessed as an exact-owner cleanup after runtime; no broad Authentik group deletion.
