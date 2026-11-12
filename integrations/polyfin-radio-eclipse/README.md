# Radio France — Eclipse music catalog

**17 direct streams:** FIP + 12 FIP thematic web stations (including Cultes and Sacré français !), plus France Inter, France Info, France Musique and Mouv'. Addon manifest v0.2.0 and 17 self-hosted PNG station thumbnails.

## Architecture

- Eclipse `contentType=music`, `track` entries, `format=mp3`, `streamURL` pointing **directly** to Radio France's official `icecast.radiofrance.fr` URLs.
- `artworkURL` references each static PNG in this repository, via `raw.githubusercontent.com`; artwork alone passes through Polyfin's standard image cache. **Audio never passes through Kubernetes or Cloudflare.**
- Original station IDs kept (fip, fip-rock, fip-jazz, fip-electro, France Inter, France Info, France Musique, Mouv') to preserve bookmarks and listening history.
- Album label `Radios en direct` is retained for Eclipse music models; users browse via **Ma musique → Radio → Chansons**, not Live TV.
- Thumbnails are **locally authored typographic identification cards**, not official Radio France artwork or logos. They avoid third-party hotlink failures and brand image licensing uncertainty. Distinct colors and labels per station. Update PNGs and catalog together.

## Sources & runtime validation

- Radio France public Open API docs for historical webradios: https://developers.radiofrance.fr/doc/tutorial-by-example/list-locals-and-webradios
- Current FIP Cultes: https://www.radiofrance.com/presse/fip-cultes-un-lancement-stratospherique
- Additional current URLs (including Sacré français, Cultes) confirmed against a Jan 2026 indexed radio directory: https://sites.google.com/view/flux-radios/Radios-France/France-Radio-France/Fip-Webradios-France
- Runtime streaming endpoints are **not tested by static GitHub CI**: after merge, confirm Polyfin refreshes the manifest/catalog, 17 tracks exist, all artwork loads via HTTP 200/PNG, then listen to **FIP Cultes**, **FIP Sacré français !**, and three other new streams for 30s each. Preserve the already qualified FIP 5-minute PASS.
- A change in manifest version may require reinstall/refresh of the existing addon from the admin interface. Do not delete the music library or replace the addon identity.
