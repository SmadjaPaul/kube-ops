# PLT-118 — TorBox / Decypharr staged pilot

This package becomes part of the Media root *after this PR is merged*.
**The PR MUST stay draft/unmerged until secret provisioning, code review,
Configarr schema validation and the admission procedure are ready.**
No runtime mutation is performed by the PR itself.

- Decypharr v2.5 pinned; internal-only API at TCP/8282.
- TorBox is the only configured debrid provider, supplied via
  `APP_TORBOX_API_KEY` (Doppler `cluster/prd` via `doppler-cluster` ESO).
- Reuse existing `APP_RADARR_API_KEY`, `APP_SONARR_API_KEY`; never commit values.
- Upstream v2.5 requires env variables named `DECYPHARR_...`, not unprefixed.
- Seed JSON keeps `debrids: []` and `arrs: []`; env overrides fill arrays.
- `download_uncached=false` is default; test no unexpected cache misses.
- `default_download_action=download`, `mount.type=none`: actual local
  downloads into `/data/decypharr-downloads`, not STRM/FUSE/SYS_ADMIN.
- `use_auth=true`. Qualify initial admin setup and QBitTorrent compatibility.
- Cilium allows only Radarr/Sonarr -> Decypharr 8282 and Decypharr
  -> Arr APIs / TorBox HTTPS. No public ingress route.
- Existing SABnzbd preserved until a completed legal fixture import + playback.
- Configarr is separately staged, suspended and DRY_RUN=true. Only it
  should own managed Arr download-client definitions after approval.

## Codex operator gates

1. Confirm exact HEAD/PR and compare active runtime with desired state.
2. Provision `APP_TORBOX_API_KEY` securely in Doppler via an authorized
   secret store workflow; never pass credentials as process arguments,
   into Git, PR comments, terminal output or Linear.
3. Validate `ExternalSecret/decypharr-api` Ready and launch the pilot
   only after merge authorization and pre-merge Configarr schema review.
4. Validate Decypharr `/version` and auth, TorBox API connectivity,
   Pod-to-Pod Cilium, shared /data mount and no secret leakage.
5. Trigger **one** operator-authorized Configarr *dry run only*; compare
   redacted diff. Do NOT unsuspend CronJob or disable DRY_RUN.
6. Explicitly authorize exactly two native client creates only after
   the diff and network validation PASS.
7. Execute an authorized freely redistributable test media item; verify
   local physical file, completed Arr import and Jellyfin playback.
8. Confirm idempotence and rollback. Never claim PLT-118 E2E PASS until
   a real authorized source/indexer and user tests pass.
9. When/if SABnzbd is disabled in a separate PR, keep PVCs and config
   until decommission is explicitly approved.

Upstream references:
- https://decypharr.com/guides/arrs/
- https://decypharr.com/guides/debrid/torbox/
- https://github.com/sirrobot01/decypharr/blob/v2.5/internal/config/env.go
- https://configarr.de/docs/configuration/config-file/
