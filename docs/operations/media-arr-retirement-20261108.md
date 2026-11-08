# Arr / Seerr retirement — 2026-11-08

## Decision
The owner explicitly accepts losing ALL application data for the obsolete media acquisition/request stack. Retire **Radarr, Sonarr, Prowlarr, Bazarr, Lidarr and Jellyseerr/Seerr**. No migration is required for their private settings and queues.

Polyfin is the replacement direction, but it is not a reason to delete shared media infrastructure: **retain** AIOStreams, Polyfin, Jellyfin, Decypharr, `media-share`, audiobook services/BookOrbit pilot, and Immich. RDT-Client, Sabnzbd and Recyclarr sources are already absent from the parent active media Kustomization; do not accidentally activate them.

## Declarative change in this PR
- Remove `arr`, `jellyseerr` and `jellyseerr-secrets.yaml` from `k8s/applications/media/kustomization.yaml`.
- Remove dedicated daily backup Schedules for radarr/sonarr/prowlarr/lidarr/bazarr/jellyseerr from the Velero Kustomization (do not modify other schedules).
- Remove dedicated Arr/Prowlarr Cilium policies from the media policies Kustomization.
- Retain the historical source manifests for audit/rollback, but exclude them from the active Kustomize graph.

## Acceptance — require observed evidence
1. `kustomize build k8s/applications/media` must not include StatefulSet/Service/HTTPRoute for the six retired apps, but must still include active Polyfin, Jellyfin, AIOStreams, Decypharr and shared storage.
2. Render Velero and media policy overlays and show only the retired resources disappear. Confirm no other namespace or critical policy was altered.
3. Confirm Git commit SHA, CI contract checks, merge, Argo `apps-media` and relevant infrastructure app reconciliation. Verify the unwanted workloads/HTTPRoutes/Services have actually been pruned, **not merely** removed from Git.
4. In the live cluster, inventory `kubectl -n media get pvc,pv` / Longhorn objects and their owners. Delete *only* individual `config-<app>-0` PVCs proven to belong to the retired apps after the workload is gone. Verify data is disposable; never delete `media-share` or Polyfin/Jellyfin/AIOStreams/Decypharr data. StatefulSet PVCs can remain after StatefulSet deletion; GitOps prune is not proof of PVC deletion.
5. Audit orphaned secrets, Doppler keys, Authentik apps/Outposts and portal bookmarks; remove only exact owners after checking no consumer. `daily-sabnzbd.yaml` is not included by the current Velero Kustomization; classify it as dormant, not an active Schedule.
6. Record resources, volumes and estimated freed resources from measured runtime metrics; never invent capacity or RAM savings. Test Polyfin and AIOStreams once more after prune.

**Safety:** No direct `kubectl delete -f` over a whole directory, no namespace deletion, no indiscriminate PVC/Longhorn garbage collection, no deletion of shared Doppler credentials, and no reset of unrelated databases or Factory. The removal is user-approved only for the named retired services. Keep normal GitHub protection/CI/Argo gates.
