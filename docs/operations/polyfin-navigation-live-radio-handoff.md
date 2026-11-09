# PLT-134 / PLT-135 — Polyfin library navigation and audio-only Live TV

## Scope and frozen baseline
Maintain official upstream Polyfin (no permanent fork or downstream image), Authentik, Nebula/Eclipse, the existing single AIOStreams addon and working direct CDN playback. Browser playback of films, series and anime is already PASS. Eight Radio France MP3 channels were imported but disabled after failing with "bytes of no known container"; never remove them without a separate rollback decision.

## A. Duplicate Films and Series links

Polyfin maps **each Stremio catalog** to a Jellyfin library. The AIOStreams Popular, Populaire, Trends, Year and Language catalogs produce separate library menu entries. These entries are not native web-player filters.

Official reference: https://github.com/moodiness/polyfin/blob/v0.61.1/docs/addons-and-libraries.md

- The admin's Content > Libraries page can rename, reorder, enable and disable catalog libraries.
- The option **Hide from the web player's top bar** (API field hideInMenus) hides a menu entry in jellyfin-web **but retains its home-screen row** and does not affect other Jellyfin apps.
- Removing a catalog **library** from the saved libraries list removes its menu/home entry **without uninstalling the AIOStreams source** or removing the source's stream service. Back up the exact library configuration first and protect Ma musique, anime discovery, user overrides, favorites and viewing progress.
- A **Smart List** aggregates titles from multiple catalogs but lacks the native interactive genre filter and has its own sort. Do not substitute it when the operator explicitly wants native filters.
- The practical supported layout is one primary Films and one primary Séries catalog, selected by real coverage, genre/year filter support, language and catalog search. Keep other AIOStreams catalogs available as a source/for search or smart discovery without unnecessary library entries.

### Prepared read-only inventory

Commands:
    node --test scripts/polyfin-library-layout-audit.test.mjs
    node scripts/polyfin-library-layout-audit.mjs

The script uses the existing authorized native admin cookie helper with GET /admin/api/scopes/shared/libraries only; hashes source/catalog identifiers, never outputs manifest URLs or secrets, and **cannot apply changes**. Five local unit tests have passed. The operator or Codex must compare actual primary catalog coverage before a native configuration update.

API reference: https://github.com/moodiness/polyfin/blob/v0.65.0/docs/scripts/screenshots/stage.mjs (reads libraries and saves the chosen library list).

Acceptance: one Films / Séries / Musique navigation, native filters in each primary library, no repeated home rows, no degradation to anime, Nebula, AIOStreams or family users. Verify Settings > Home individual preferences and both jellyfin-web and at least one client.

## B. Live video TV versus Internet radio

Polyfin supports **video Live TV** via Stremio catalogs of type tv, M3U, Xtream Codes and HDHomeRun. The 13 movie/series catalogs do not prove an actual live-tv catalog or legally playable video channel. Use a rights-compliant operator-verified direct video source with real video/audio, and test browser playback, stream permissions and optional guide before labeling LIVE_TV PASS.

Official sources:
- https://github.com/moodiness/polyfin/blob/v0.65.0/docs/live-tv.md
- https://github.com/moodiness/polyfin/blob/v0.65.0/docs/iptv.md
- https://jellyfin.org/docs/general/server/live-tv/internet-radio/

**Radio reference mismatch:** Jellyfin explicitly documents Internet radio via M3U Live TV tuner. Jellyfin issue https://github.com/jellyfin/jellyfin/issues/17124 says FIP MP3 works in web Live TV but audio-only DLNA casting still fails: not universal client compatibility.

Polyfin v0.61.1 through v0.65.0 rejects raw MP3 before normal analysis in internal/playback/feed.go::Service.sniff(). It admits HLS and DASH manifests, MPEG-TS packets and MP4 boxes; otherwise returns ErrLiveDead "bytes of no known container". The M3U radio entries themselves are valid and the source imports. Repeated HEAD checks or changing Radio France MP3 URLs cannot fix that check. Reference: https://github.com/moodiness/polyfin/blob/v0.65.0/internal/playback/feed.go

### Upstream contribution specification

1. Check for existing upstream issue/PR and latest tag; reproduce with a public FIP MP3 M3U, never secret URLs.
2. Prepare upstream issue with precise Error, code references, Jellyfin reference, and a no-secrets reproduction.
3. Do NOT simply allow MP3 magic bytes in sniff: trace downstream analysis, live feed type, video-keyframe assumptions, Jellyfin PlaybackInfo, web-player audio-only rendering, FFmpeg relay/remux and reconnection. Implement a coherent audio-only branch.
4. Regression matrix: Icecast MP3, AAC/ADTS where available, HLS audio-only, HTTP redirect, disconnect/reconnect, short/error/HTML body, video MPEG-TS/HLS/MP4 unchanged; actual browser and one compatible Jellyfin client. Do not claim DLNA support without testing.
5. Upstream merge and official image release only; Renovate handles deployment after safety checks. No custom Polyfin image, permanent fork or synthetic video transcoding proxy.
6. Keep eight radios disabled until playback works. M3U group-title Radios creates a group **inside Live TV**; a new top-level Radio menu is a separate upstream UI feature, not automatic.

## Codex next actions

1. Run the inventory script; choose primary movie and series catalog by live evidence and record the exact old library list securely. Prepare and apply a reversible native library configuration (separate explicit approval for destructive scope, if needed).
2. Prove browser menu and native filters, ensure home rows and other clients are considered; keep source, user state and music.
3. Identify a verified free/legal live **video** fixture, and play it in Polyfin. No fabricated channels or EPG.
4. Prepare an upstream radio issue and focused tests; no production fork. If no upstream solution yet, radios remain disabled.
5. Update PLT-135 with evidence and stop. Do not reopen completed PLT-134 or rescan already qualified CI/security/infrastructure.
