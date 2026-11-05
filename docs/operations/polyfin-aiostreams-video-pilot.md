# Polyfin 0.60 — AIOStreams Stremio pilot (PLT user apps)

This is a **preflight and gated native install** into the existing
`https://media.smadja.dev` Polyfin. AIOStreams already runs independently at
`https://aiostreams.smadja.dev`, and Nebula/Eclipse music is already installed.
No new workload, HTTPRoute, SQL migration, addon reconfiguration, or changes to
`tv.smadja.dev` are made by this helper.

Polyfin v0.60 (upstream `internal/admin/addons.go`) supports
`POST /admin/api/scopes/shared/addons` with `{manifestUrl}`, automatically
detects the `stremio` addon kind and creates default-enabled libraries from
compatible video catalogs (up to its current library limit).

## Safe source of truth

Use the **already configured and authorized** AIOStreams Stremio profile
manifest URL. It may contain a token and must be stored as a local
restricted file (0600) or obtained from an approved secret provider, never in
command arguments, Git, Linear, debug logs, screenshots or shell history.
Do NOT substitute the admin UI URL or Nebula manifest.

```sh
export POLYFIN_AIOSTREAMS_MANIFEST_URL_FILE=/secure/path/aiostreams-manifest-url
node scripts/polyfin-aiostreams-pilot.mjs
node --test scripts/polyfin-aiostreams-pilot.test.mjs
```

Dry-run verifies HTTPS `aiostreams.smadja.dev` exact host and Stremio
`stream` resource, movie/series type and catalog shape; prints only safe
booleans and counts. It **does not** install anything or call TorBox.

### Explicit, authorized installation

Once the operator has verified the intended source and the server can
access the manifest through the private Gateway, use one of the already
qualified Polyfin native administrator auth modes:

- `POLYFIN_ADMIN_COOKIE_FILE`, **or**
- `POLYFIN_ADMIN_USERNAME_FILE` and `POLYFIN_ADMIN_PASSWORD_FILE`

The existing Nebula helper checks native `/admin/api/session` for
`isAdministrator=true`. Never use ordinary family OIDC credentials
as admin, and never print cookies or paths. Apply is **opt-in**:

```sh
POLYFIN_APPLY_AIOSTREAMS=YES node scripts/polyfin-aiostreams-pilot.mjs --apply
```

If another Stremio addon with the same ID exists, the helper returns
`EXISTING_ADDON_ID_REVIEW_PROFILE` without editing it; tokenized profile
URLs may differ even with identical Stremio IDs. Inspect the existing
profile in the native admin UI without leaking the URL.

If a stream-only manifest has no catalog, choose complementary metadata/
catalog sources rather than assuming empty libraries mean installation
failed. Inspect **Content -> Sources** and **Content -> Libraries** after
admission; record only names, kinds and enabled counts.

## Acceptance — not yet executed

1. From the Polyfin Pod, HTTPS manifest read with TLS verification and
   Cilium/Hubble FORWARDED, only sanitized request metadata.
2. Private admin installs one Stremio addon without replacing Nebula or
   creating duplicate profiles. Family user sees movie and series catalogs.
3. Resolve **one legally accessible video fixture** from AIOStreams, record
   only CDN hostname, HTTP status and codec metadata. Direct play must
   redirect client→CDN wherever compatible; do not relay through K8s or
   Cloudflare by default. Test FR/EN plus FR subtitles on an authorized
   fixture.
4. Confirm two independent users cannot access each other's accounts,
   continue watching and watch history. Test Safari/Brave/Apple TV/Android
   where clients exist, with honest NOT_EXECUTED for missing devices.
5. No changes to `tv.smadja.dev` or AIOStreams terraform provider
   configuration. Keep a rollback plan to remove *only the new addon* using
   Polyfin native API if tests fail (do not destroy sources/data).

## Live TV remains a separate local-only pilot

Polyfin v0.60 supports M3U, Xtream Codes and HDHomeRun directly
(see upstream `docs/iptv.md`, `docs/live-tv.md`). Do not invent a playlist,
Xtream credentials or provider. Stage the **operator-authorized LAN
source** first; allow private source access only from the admin-owned
scope with explicit Cilium destination rules. Do not reuse public
AIOStreams sources for live IPTV. Test channel list, EPG, first channel,
and live playback, then qualify client and reconnection.

Docs:
https://github.com/moodiness/polyfin/blob/v0.60.0/docs/addons-and-libraries.md
https://github.com/moodiness/polyfin/blob/v0.60.0/docs/iptv.md
