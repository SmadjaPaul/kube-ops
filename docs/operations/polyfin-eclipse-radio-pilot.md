# PLT-135 — Eclipse Radio France pilot (without changing Nebula or Polyfin)

## Architecture decision
Nebula is an Eclipse music addon specialized in music search and resolving tracks through TorBox, **not** a terrestrial/live-radio directory. Eclipse's user-facing "Radio" and "Stations" features generate recommendations from songs/artists/genres; they are distinct from an Icecast broadcast.

A separate minimal Eclipse addon is the compatible route:
- Server serves **JSON metadata only** as a Cloudflare Worker (no state/database/credentials).
- Polyfin installs **one additional music source**, alongside Nebula unchanged. Enable its catalog as a music library, rename it "Radio" and order it with "Films / Séries / Anime / Musique" via native Content > Libraries.
- GET /catalog/stations returns eight Radio France entries as tracks; GET /stream/{id} returns the official HTTPS Icecast MP3 URL. **Worker never fetches, transforms, proxies, caches or transmits audio**.
- Polyfin may redirect the audio to the client or relay it when required by playback policies. The household explicitly accepts low-volume radio traffic through the homelab/Cloudflare; confirm with a real playback and network observation rather than assume any delivery mode.
- Do NOT change Nebula's endpoint, TorBox usage, Polyfin image or addon source order/default. Do NOT set the Radio France addon as music's default playback resolver; a station is not a song and has no real ISRC.
- If Polyfin can't handle a never-ending track with unknown duration through Jellyfin's audio pipeline, **stop the pilot** and open an upstream issue with the exact PlaybackInfo/Audio endpoint traces. Do not fabricate a 24-hour song duration, fake ISRC, or build a permanent transcoding proxy.

## References
- Eclipse addon protocol: https://eclipsemusic.app/docs
- Nebula setup (TorBox key/metadata): https://nebula.eclipsemusic.app/
- Polyfin music addons/stream decision: https://github.com/moodiness/polyfin/blob/v0.65.0/docs/music.md
- Polyfin catalog codec parsing: https://github.com/moodiness/polyfin/blob/v0.65.0/internal/eclipse/client.go
- Polyfin audio playback path: https://github.com/moodiness/polyfin/blob/v0.65.0/internal/jellyfin/audio.go
- Radio France streaming sources: existing kube-ops ConfigMap at k8s/applications/media/polyfin/radios-configmap.yaml
- Optional future discovery only: Radio Browser https://docs.radio-browser.info/ (public user-submitted URLs need validation/allowlisting; do not fetch arbitrary URLs server-side).

## Files
- integrations/polyfin-radio-eclipse/worker.mjs
- integrations/polyfin-radio-eclipse/worker.test.mjs
- integrations/polyfin-radio-eclipse/wrangler.toml

## Run local tests
    cd integrations/polyfin-radio-eclipse
    node --test worker.test.mjs
    npx wrangler@4 deploy --dry-run

No Node packages are needed to run the unit tests. Deploy uses Wrangler and an authorized Cloudflare account; the Worker service is not part of the existing cluster, so don't blindly mutate K8s or install an untracked component. Prefer the organization's established Cloudflare IaC or automated deployment if supported, retaining rollback to previous Worker version. NEVER publish private TorBox or family URLs.

## Runtime pilot, with no production mutation before an authorized deploy
1. Deploy Worker to a domain/routes authorized by account owner (workers.dev is fine for pilot). The Worker is public **metadata only**.
2. GET /manifest.json, /catalog/stations?skip=0 and /search?q=FIP, confirm 8 unique stations; GET /stream/fip yields the official Radio France MP3 URL. Test HEAD/OPTIONS and Content-Type/CORS. No radio bytes through the Worker.
3. In Polyfin, Content > Sources > Add source > Eclipse addon, install worker endpoint/manifest as one new source. Keep Nebula unchanged. Content > Libraries: enable the Radio catalog and rename its library Radio. Don't expose user-specific credentials.
4. Open jellyfin-web on Brave and run a live FIP stream for at least 5 minutes, then stop and restart; verify the player doesn't advance to another station, doesn't seek, doesn't show fake duration, doesn't buffer forever, and the audio remains active. Test on compatible mobile device too. Observe /Audio/.../stream, PlaybackInfo/MediaSources, redirect vs relay and the bytes through gateway, with no tokens in logs.
5. If successful, try France Inter and FIP Jazz, verify search, favorite, multi-user isolation and navigation ordering. Only then enable more stations/auto-discovery.
6. If failure: observe the exact API and player error, document minimal upstream Polyfin reproduction and rollback by disabling the Radio library/source. No change to eight legacy disabled Radio France **Live TV** channels.
7. Album/playlist metadata is deliberately not provided. Radio appears as its own **music library**. A dedicated "Radio" nav label is a library name, not a new Polyfin Live TV type. No extra homepage navigation hacks.

## User navigation target
- Radio = Eclipse Radio France addon as one library.
- Musique = existing Nebula/Eclipse source, unchanged.
- Films & Séries = Cinemeta primary libraries; AIOStreams remains as stream addon.
- Anime = first evaluate whether one existing Stremio anime catalog can be enabled separately; otherwise use a targeted smart list, accepting its lack of native interactive genre filter, and verify anime visibility and audio/subtitle preferences.
- No TV video bouquet and no general IPTV-proxy project.

## Explicit gates
- OFFLINE_PILOT=PASS when Node tests and Wrangler dry-run pass.
- ECLIPSE_API=PASS after deployed HTTPS endpoints are checked.
- POLYFIN_RADIO_LIBRARY=PASS only after native install and radio catalog visible.
- RADIO_PLAYBACK=PASS only after real browser listening (>=5 minutes) and restart; codec/unknown duration issue is UNPROVEN until then.
- CLOUDFLARE_MEDIA_EGRESS: never infer direct play; measure if the audio traverses Polyfin/gateway.
- Keep PLT-135 active while radio playback is unproven, and do not reopen PLT-134.
