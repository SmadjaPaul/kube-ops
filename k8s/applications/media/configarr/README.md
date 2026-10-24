# PLT-118 — Configarr 1.35.0, staged preview

This is an **activated but suspended** Configarr preview package. It is listed
in `k8s/applications/media/kustomization.yaml`. Merging config-only changes
will reconcile ConfigMaps; however
`CronJob/configarr-preview` remains `suspend: true` and `DRY_RUN=true`.

## Why

The 2026-10-23 runtime audit found Seerr requests #2/#3 pending, no Arr
connections, zero root folders/download clients, no Prowlarr indexers and no
active Usenet server. Running Helm/Kustomize alone does not populate an app's
persistent settings. Configarr is the upstream GitOps candidate for Radarr,
Sonarr and Prowlarr; Seerr/Jellyfin require a separate native-API bootstrap.

## Scope and ownership

| Field | GitOps owner | Admission |
| --- | --- | --- |
| Radarr movie root folder | Configarr | Preview only; root folder sync is destructive |
| Sonarr TV root folder | Configarr | Preview only; do not overwrite existing folders |
| Prowlarr links to Radarr/Sonarr | Configarr experimental | Preview only |
| Indexers/provider accounts | No owner yet | BLOCKED: external source |
| Download client and categories | No owner yet | BLOCKED: choose/verify downloader |
| Radarr/Sonarr quality profiles | Staged Recyclarr (not active) | Do not run simultaneously with Configarr quality management |
| Seerr server definitions/permissions | Seerr native API, future batch | Not implemented |
| Jellyfin movies/series libraries | Jellyfin native API, future batch | Not implemented |
| SABnzbd server | Existing env-driven entrypoint | External credentials; disabled |

Root paths intended: `/data/media/movies` and `/data/media/tv`.
Internal Kubernetes Service port is **80**; container listeners are 7878,
8989 and 9696. Configarr's experimental Prowlarr `applications` links use
`addOnly`, with removal disabled and `sync_indexers=false` until an
authorized indexer is configured.

## Activation checklist (operator / Codex)

1. Check the actual latest git revision and persistent Arr settings, backup
   config PVCs, and confirm no parallel owner of the same keys.
2. Using operator harness, verify the names (not values) of Doppler
   `cluster/prd` secrets `APP_RADARR_API_KEY`, `APP_SONARR_API_KEY`
   and `APP_PROWLARR_API_KEY`. Establish them from genuine Arr app APIs
   without logging values. Missing keys are BLOCKED; do not generate guesses.
3. Review the actual Configarr 1.35.0 executable/entrypoint, Linux image
   digest, UID, cache paths and tag support. The staged manifest is pinned to
   the verified multi-architecture digest; re-verify it before activation.
4. Validate `kustomize build k8s/applications/media/configarr` and
   kubeconform/schema/contract checks. The package must remain absent from
   the media root until an independent review authorizes staged deployment.
5. In a separate PR, add the package to the media root. Verify
   `configarr-arr-api` ExternalSecret Ready, policy DNS/API egress, and
   `CronJob` still suspended.
6. Trigger *one* explicitly named **dry-run** Job from the suspended CronJob,
   review redacted stdout and JSON diff. Do not turn off `DRY_RUN`.
   Inspect removals of root folders and any credentials in diff files.
7. After a reviewed preview, choose field owners and admit the minimum
   actual changes on a separate exact-SHA PR with rollback. Never run
   Recyclarr + Configarr concurrently on quality definitions/profiles.
8. Verify Seerr/Arr and Prowlarr/API links in runtime, after restart and
   after a no-op re-run. Do not mark media downloads PASS without a real
   authorized source, completed import and Jellyfin playback.

This pilot creates **no indexer**, does **not** enable qBittorrent/Decypharr
or any Usenet subscription, does not approve historic Seerr requests, and
does not change existing Jellyfin SSO or PVC data.

## Reference

- https://configarr.de/docs/installation/kubernetes/
- https://configarr.de/docs/configuration/config-file/
- https://configarr.de/docs/configuration/experimental-support/
- https://configarr.de/docs/configuration/environment-variables/
- https://configarr.de/docs/configuration/general/

## TorBox / Decypharr pilot

- Staged qBittorrent-compatible download_clients point at `decypharr:8282`.
- Username = per-Arr API URL, password = per-Arr native API token (`!env`).
- Native client changes remain dry-run only; do not unsuspend CronJob.
- `delete_unmanaged.enabled=false`; no indexers are generated.
