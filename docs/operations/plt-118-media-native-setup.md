# PLT-118 — bounded native Seerr and Jellyfin configuration

State: **operator tool only, not admitted for execution**. It creates no
Kubernetes controllers, jobs, secrets, profiles, indexers or downloaders.
It does not touch Authentik/OIDC, media requests, or existing PVC data.

The one-shot script uses the applications' own documented APIs:
- Seerr GET/POST /api/v1/settings/radarr and /sonarr; authentication X-Api-Key:
  https://docs.seerr.dev/api/seerr-api/
  https://docs.seerr.dev/api/create-radarr-instance/
  https://docs.seerr.dev/api/create-sonarr-instance/
- Jellyfin GET/POST /Library/VirtualFolders; X-Emby-Token:
  https://jellyfin.org/docs/general/server/libraries/
  https://typescript-sdk.jellyfin.org/functions/generated-client.LibraryStructureApiFp.html

## Preconditions (NO secrets in shell history or logs)

Use the canonical kubeconfig preflight per AGENTS.md for cluster diagnosis,
not ~/.kube/config. Run from a trusted operator environment that can resolve
and reach the headless Services (usually an explicitly authorized in-cluster
operator pod or scoped localhost port-forwards).

Provision **existing** credentials from Doppler/ESO without echoing values:
- JELLYFIN_API_KEY: pre-existing Jellyfin administrator API key (historically
  APP_JELLYSEERR_JELLYFIN_API_KEY if available).
- SEERR_API_KEY: pre-existing Seerr general settings API key; may be missing,
  and MUST NOT be regenerated automatically.
- RADARR_API_KEY, SONARR_API_KEY: corresponding existing Arr keys.
Do NOT commit values, pass credentials as command-line arguments, or log API
response bodies; Seerr settings GET/POST contains API keys.

Other env values when working inside the cluster:
- JELLYFIN_URL=http://jellyfin.media.svc.cluster.local:8096
- SEERR_URL=http://jellyseerr.media.svc.cluster.local:5055
- RADARR_URL=http://radarr.media.svc.cluster.local:7878
- SONARR_URL=http://sonarr.media.svc.cluster.local:8989
- RADARR_PROFILE_NAME and SONARR_PROFILE_NAME: **exact** profile names read
  from each Arr instance. No default IDs or profiles are invented.

From a suitably authenticated execution context, run:

    python3 scripts/media/plt118-native-setup.py jellyfin
    python3 scripts/media/plt118-native-setup.py seerr

These are read-only by default. Compare expected operations to current
libraries and service settings. In particular confirm real quality profile IDs,
root folders, namespace labels, mount paths, permissions and library visibility.

For the four approved additions ONLY, run one controlled invocation per target:

    python3 scripts/media/plt118-native-setup.py jellyfin --apply
    python3 scripts/media/plt118-native-setup.py seerr --apply

Apply mode fails on existing conflicting names/paths/default servers, verifies
each creation by rereading the API, and never removes or updates an existing
library or service. It creates no request, does not approve pending requests,
and uses Seerr preventSearch=true / syncEnabled=false until downloader and
indexers are separately qualified.

Rerun without --apply and demand NO_CHANGES. After Jellyfin libraries exist,
trigger a native Jellyfin scan in a separately approved action, check the
library paths survive application restarts and Seerr library sync. Do not
call an empty library a successful download/import.

Never run apply concurrently from two agents. Do not invent an external
Usenet/BitTorrent provider, indexer or payment. Report prerequisites as BLOCKED.
The script intentionally refuses to pick quality profiles or overwrite
existing Seerr/Jellyfin configuration automatically.

Current acceptance:
- STATIC only once tests pass; no Argo mutation or runtime test from adding
  this script.
- Seerr USER and Jellyfin USER: NOT_EXECUTED until operator evidence.
- DOWNLOAD_E2E: NOT_EXECUTED until a lawful media source and actual import.

PLT-118 stays the canonical ticket; PLT-54/96 remain Done.
