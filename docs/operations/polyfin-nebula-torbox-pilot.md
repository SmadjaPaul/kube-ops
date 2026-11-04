# Polyfin 0.60 — Nebula/TorBox Eclipse music pilot

**Stage only, 2026-11-04.** This does not install the addon, rotate credentials, add
media egress, enable public access or change the Polyfin database.

## Target topology

- **Video:** the existing configured AIOStreams *Stremio manifest* is consumed
  as a shared addon by Polyfin. No duplication of TorBox, Comet or metadata
  addon configuration. The separate AIOStreams Jellyfin endpoint is not an
  addon manifest.
- **Music:** Nebula/TorBox is a distinct **Eclipse** addon configured in Polyfin
  through its native \`POST /admin/api/scopes/shared/addons\` interface.
- **Live TV:** a separately authorized M3U/Xtream + XMLTV source, LAN/VPN only.
- **Users:** Polyfin/Authentik OIDC for the web; Jellyfin-compatible sessions
  for clients. Never confuse an Eclipse desktop account with a Polyfin account.

Nebula's [configurator](https://nebula.eclipsemusic.app/) accepts a TorBox
API key and produces a **credential-bearing installation URL**. This URL is a
secret, even if it resembles a normal manifest URL. Do **not** paste it into
GitHub, Linear, chat, shell history or command arguments. Nebula is a
third-party service that receives that key. Use a dedicated/revocable key
if TorBox provides that capability, and review the access scope.

## Implemented but not activated

- Scoped Cilium HTTPS egress to the verified Nebula configurator host
  \`nebula.eclipsemusic.app\` only, adjacent to SoundCloud; it does **not**
  open \`world:443\`, TorBox media CDN traffic, or additional hosts.
- Dormant ESO overlay \`k8s/optional/polyfin-nebula\` points to Doppler key
  \`APP_POLYFIN_NEBULA_MANIFEST_URL\`. It is intentionally **not** in the
  active media kustomization: activating it before the key exists would
  create a NotReady ExternalSecret.
- \`scripts/polyfin-nebula-pilot.mjs\` validates the actual manifest and
  offers an explicitly authorized \`--apply\` using an existing Polyfin
  administrative session. It never prints the tokenized URL or admin cookie.
- \`scripts/polyfin-nebula-pilot.test.mjs\` exercises offline
  protocol and secret-redaction cases.

## Activation procedure (operator/Codex; after Argo reconciles)

1. Generate an install URL from the official configurator using an approved
   TorBox key; keep AirLock disabled initially so a quota threshold cannot
   masquerade as a playback problem. Enable it only after measuring usage.
2. Verify the generated URL's *hostname* and its precise manifest path
   **without logging the URL**. If it differs from the reviewed
   \`nebula.eclipsemusic.app\` host, stop; qualify that FQDN and adjust the
   NetworkPolicy and preflight host pin in a new minimal GitOps PR.
3. Store the entire URL in Doppler cluster/prd as
   \`APP_POLYFIN_NEBULA_MANIFEST_URL\`. Do not add a plaintext ConfigMap.
4. Activate the dormant ESO overlay in the active media kustomization
   **only once the Doppler key exists**. Observe \`SecretSynced=True\`.
5. Supply the URL to the preflight helper as a local **restricted-permission
   file** via \`POLYFIN_NEBULA_URL_FILE\`. For example, Codex may securely
   materialize the ESO secret in its authorized operator environment.
   It must not print the content. Run:
   \`node scripts/polyfin-nebula-pilot.mjs\`
   This probes the real manifest without installing it.
6. Authenticate through **Polyfin's official native session API**.
   Preferred: provide the existing Polyfin administrator name/password through
   local restricted-permission files at \`POLYFIN_ADMIN_USERNAME_FILE\` and
   \`POLYFIN_ADMIN_PASSWORD_FILE\`. The helper performs
   \`POST /admin/api/session\`, extracts the HttpOnly
   \`polyfin_session\` cookie in memory, and verifies
   \`GET /admin/api/session\` with \`isAdministrator=true\`.
   No session cookie, password or token is printed or written to disk by
   the helper. Two-step sign-in needs an authorized interactive method.
   Alternative: supply an already-authorized Cookie header via
   \`POLYFIN_ADMIN_COOKIE_FILE\`. Do not combine the two modes.
   Run \`POLYFIN_APPLY_NEBULA=YES node scripts/polyfin-nebula-pilot.mjs --apply\`.
   Verify \`kind=eclipse\` after installation through the native API.
   If no password nor cookie exists, stop at \`MISSING_ADMIN_AUTH\`:
   do not reset accounts, bypass login or invent credentials.
7. Verify the actual \`search\`, \`catalog\`, \`album\`, \`artist\` and
   \`stream\` resources claimed by the manifest. A search-only addon
   yields Polyfin's synthesized **My music** library, not necessarily
   rich albums and artists. Check enabled library count before reporting PASS.
8. Read one already-cached authorized track and one uncached track.
   For each, provide its ID only through `POLYFIN_NEBULA_TRACK_ID_FILE` and run
   `POLYFIN_RESOLVE_TRACK=YES node scripts/polyfin-nebula-pilot.mjs --resolve-track`.
   This calls Nebula's native `/stream/{id}` and prints only latency, CDN
   hostname and audio metadata; no signed URL or track ID. **This may
   initiate TorBox caching and consume quota**: execute it only for tracks
   the operator has authorized, never automatically in CI.
   **Do not automatically invoke an uncached track in CI:** Nebula may
   initiate TorBox caching. The upstream Polyfin v0.60 client gives
   addon calls a 15-second timeout. Record warm/cold latency, status and
   whether any 15-second failure is reproducible; do not increase
   global timeouts or fork Polyfin without evidence.
9. Inspect only **sanitized** CDN hostnames and response metadata, then
   compare Polyfin 302 direct-play against relay/HLS network bytes. Admit
   any *actually needed* server-side egress by exact observed FQDN only.
   If bytes go directly to the client, no Pod CDN egress may be needed.
10. Confirm real OIDC user login, two separate accounts, music library
    visibility, Web Player playback, and compatible Jellyfin clients.
    Keep the external route disabled and IPTV LAN/VPN only.

## Gates

\`ARGO_REVISION_PASS\` — \`NEBULA_MANIFEST_PASS\` —
\`NEBULA_SOURCE_PASS\` — \`MUSIC_LIBRARY_PASS\` —
\`TORBOX_WARM_STREAM_PASS\` — \`TORBOX_COLD_STREAM_PASS\` —
\`DIRECT_PLAY_PASS\` — \`OIDC_USER_PASS\` — \`USER_READY\`.

A valid manifest is **not** playback proof. A live track resolution may have
cost/quota consequences. Do not use fake approvals, fake stream URLs, or
invented PASS states. Preserve existing AIOStreams and Polyfin backups.

References: [Eclipse developer protocol](https://eclipsemusic.app/docs),
[Polyfin addon guide](https://github.com/moodiness/polyfin/blob/v0.60.0/docs/addons-and-libraries.md),
[Polyfin client timeout](https://github.com/moodiness/polyfin/blob/v0.60.0/internal/stremio/client.go),
[Nebula setup](https://nebula.eclipsemusic.app/).
