# Polyfin — family media pilot (dormant)

Status: **STAGED / NOT DEPLOYED**. The parent media Kustomization does not
reference this folder. Do not enable until all admission gates below pass.

Current admission result (2026-10-27): the upstream stable `0.50.0` image is
pinned by digest, but the security gate is **BLOCKED**. The image scan reports
six unresolved HIGH vulnerabilities (including fixes published for the
affected packages), and no verifiable Cosign signature was found for the
published digest. Keep the parent admission absent until a patched, verifiable
upstream image is available.

This is the upstream [Polyfin](https://github.com/moodiness/polyfin) Jellyfin
API server. Existing AIOStreams (TorBox, Comet, Meteor, AIOMetadata, Cinemeta)
and Jellyfin (local music) stay running unchanged. Polyfin adds individual
viewer accounts, invitations, playlists/history, Live TV and Eclipse sources.

## Intended topology

- `tv.smadja.dev` routes to Polyfin on port 8096 through the **internal**
  Cilium Gateway; split DNS resolves to `10.0.20.192`. This is a LAN/VPN-only
  pilot. No external HTTPRoute, Tunnel, public DNS or Cloudflare Access.
- App: one Pod (nonroot UID 65532, readonly rootfs), `/data` on Longhorn.
- Database: separate single-instance CNPG `polyfin-db`, with app credentials
  auto-generated in Secret `polyfin-db-app` (field `uri`).
- At-rest application secret: `POLYFIN_SECRET_KEY` from Doppler via ESO,
  key `APP_POLYFIN_SECRET_KEY`. Generate random 32 bytes and store base64,
  retain for backups; never print it.
- `/healthz` = process live; `/readyz` = PostgreSQL ready.
- Scoped Cilium egress only. The **global broad media policy explicitly
  excludes Polyfin** because Cilium allow rules are additive.

### Direct-stream boundary and Cloudflare

Polyfin can issue HTTP 302 redirects so supported clients read TorBox CDN
directly; *it can also relay, remux and transcode* when a client cannot use
the original URL. Some IPTV HLS (especially in browsers) is relayed, and
recording intentionally moves bytes through the server. Therefore:
- Test 302/Range/network bytes on Apple TV, iOS, Android TV and browser,
  not only that the stream plays.
- The initial Cilium policy **does not permit CDN or arbitrary IPTV/media
  hosts**. This is intentional staging, not fully functional playback.
  Qualify any egress change from real Hubble observations; never grant world:443.
- Only enable IPTV within LAN/VPN. If a public `tv.smadja.dev` endpoint is
  later created, a public user cannot merely be shown a hidden TV tab:
  Jellyfin API + playback paths need enforceable access isolation. Do not
  publish until remote IPTV *cannot* use the server as video relay.
- No P2P torrenting, WireGuard, inbound UDP discovery or DLNA in this pilot.

## Codex activation checklist

1. Inspect current upstream release and published multiarchitecture image.
   **Replace the staging image tag with a verified
   `ghcr.io/moodiness/polyfin:<version>@sha256:<digest>`.**
   Do not enable until pinned. Verify CVEs and upstream release changes.
2. Provision Doppler `APP_POLYFIN_SECRET_KEY` through the normal secure
   workflow, confirm ESO Ready. Do not store values in Git or shell logs.
3. Verify CNPG storage, bootstrap Secret field `uri`, backups to Hetzner
   and test a restore. Check CIDR/pod labels, supported PostgreSQL version
   and pinned image policy before admitting the root.
4. Confirm `kustomize build k8s/applications/media/polyfin` and repository
   `just check`. Add `- polyfin` to the parent Kustomization in a separate
   reviewed activation PR. No manual kubectl apply or imperative resources.
5. Verify Argo `apps-media` Synced/Healthy, `/healthz`, `/readyz`,
   Endpoints and internal TLS. Set the upstream **Known proxies** option
   using actual Gateway identity, and public address only when validated.
6. Load `/admin/`. Polyfin prints a **one-time setup code** in its own logs;
   create operator credentials interactively. Never invent/share secrets.
7. Create two non-admin **invitation** accounts and test isolation,
   password recovery, session revocation, Quick Connect and device sign-in.

## Suggested content configuration (upstream UI, not custom patches)

Use **Content → Sources → Add a source** and **Content → Libraries**.
The admin centrally manages sources for all users; disable their ability to
add personal providers until needed.

| Domain | Provider / source | Verify |
|---|---|---|
| Film & series | One existing AIOStreams Stremio manifest; keep credentials private | discover, metadata, TorBox 302 + seek |
| Anime | AIOMetadata through AIOStreams (Cinemeta fallback), seasonal catalogs | real JP audio + FR external/embedded subtitles |
| Music | Eclipse addon candidate; Jellyfin local music remains unchanged | play/seek, lyrics, playlists, Apple clients |
| Audiobooks & podcasts | Eclipse source or rights-cleared local source | resume/bookmarks; long-lived URL expiration |
| IPTV | Authorized M3U + XMLTV, or Xtream Codes, optionally HDHomeRun | EPG, categories, catch-up, live latency LAN only |

Prefer a small home set (trending movies, popular shows, anime season,
continue watching), genres through Discover, and no duplicated catalog rows.
AIOStreams requires one configuration, not one per Polyfin user. Source
manifest URLs can include encrypted credentials: never commit/log these.

For IPTV prefer a valid licensed source with an XMLTV guide for the pilot.
Keep **recording OFF** until its traffic and disk retention are separately
qualified. Restrict Live TV by user, but *do not mistake account permissions
for network-local-only enforcement*. Playlist URLs and logins are secrets.

## Acceptance matrix / rollback

- API and login: `/web/`, `/admin/`, `/healthz`, `/readyz`.
- Device E2E: Apple TV (Swiftfin / Infuse), iOS, Android TV, browser.
- At least one film, one series, one VOSTFR anime, one IPTV channel,
  one music track and one audiobook if legal test media exists.
- Verify direct video source IP/CDN and server TX/RX. A relay is FAIL for
  public TorBox playback, not a reason to broaden egress automatically.
- Backup restore CNPG + PVC + same encryption key; negative policy tests.
- Document PASS/FAIL/NOT_EXECUTED honestly.
- Rollback removes parent Kustomization entry only after reviewing
  Argo prune effects; PVC and CNPG carry `Prune=false` annotations.
  Never delete AIOStreams/Jellyfin state.

Upstream docs:
[Install](https://github.com/moodiness/polyfin/blob/main/docs/installation.md),
[Proxy](https://github.com/moodiness/polyfin/blob/main/docs/reverse-proxy.md),
[Playback](https://github.com/moodiness/polyfin/blob/main/docs/playback.md),
[IPTV](https://github.com/moodiness/polyfin/blob/main/docs/iptv.md),
[Music/addons](https://github.com/moodiness/polyfin/blob/main/docs/addons-and-libraries.md).
