# Polyfin — family media pilot (dormant)

Status: **STAGED / NOT DEPLOYED**. The parent media Kustomization does not
reference this folder. Do not enable until all admission gates below pass.

Current admission result (2026-10-27): upstream stable `0.50.0` is pinned by
digest; activation remains **BLOCKED**. A reproducible Trivy 0.76.1 scan of
`linux/amd64` on workflow run
[`40558560121`](https://github.com/SmadjaPaul/kube-ops/actions/runs/40558560121)
reports **61 HIGH/CRITICAL affected-package occurrences, 23 distinct CVEs,
including one CRITICAL**; six distinct CVEs have published fixes. The original
operator scan reported six HIGH, apparently using a narrower or
fixed-vulnerabilities-only filter: its exact command needs comparison.
Do not confuse the number of package occurrences with distinct CVEs.
No Cosign publisher signature was verified. The whole Trivy JSON and TSV
are attached as GitHub Actions artifact `polyfin-oci-trivy-amd64`.

## Reproducible vulnerability findings — 2026-10-27

Exact target:
`ghcr.io/moodiness/polyfin:0.50.0@sha256:b544e75ae8f028214d6dd1ea7fd55094b75211c081a41d7c6afe0917637cc719`
on `linux/amd64`; Trivy **v0.76.1**, Debian **13.7**, OS + library,
`HIGH,CRITICAL`, `ignore-unfixed=false`. CI keeps an immutable workflow
artifact for 14 days and **fails deliberately** when severe findings exist.
The scanner and date matter; reruns against newer advisories may differ.

| Group | Occurrences | Unique CVEs | Fixable unique CVEs |
| --- | ---: | ---: | ---: |
| Debian OS packages | 57 | 19 | 2 |
| Go standard library in Polyfin binary | 4 | 4 | 4 |
| **Total** | **61** | **23** | **6** |

**First upstream patch candidate (not a signed or validated image):**
- Rebuild Polyfin using patched Go **1.27.3** instead of upstream
  `golang:1.27.1-alpine`: four vulnerabilities in `stdlib`
  (`CVE-2026-111943`, `CVE-2026-78667`, `CVE-2026-78669`,
  `CVE-2026-97031`). Pin the updated Go base image by digest.
- Apply current Debian Trixie security updates in the *final runtime
  stage* (not merely the build stage): fixes published for
  `CVE-2026-103111` (`libpcre2-8-0`) and
  `CVE-2026-84782` (`libssl3t64`, `openssl-provider-legacy`).
- After patching: rebuild/publish with signed provenance, SBOM and
  verified OCI digest; rescan the exact `linux/amd64` candidate.
  Never assert that rebuilding from the same source automatically fixes
  unfixed Debian packages or authenticates the publisher.

**Other findings:** 17 remaining unique Debian CVEs have no fixed-version
entry in the scanner, including Trivy **CRITICAL `CVE-2026-6653`**
(`libxml2`, a malformed-XML denial-of-service scenario). Debian's
Trixie tracker describes it as `no-dsa` / minor; that is *not* a
proof of non-reachability in Polyfin, especially with XMLTV, image
processing, subtitles and FFmpeg/Tesseract dependencies. Need concrete
runtime linkage and reachable-input analysis before considering any
limited internal-pilot risk acceptance. Never bypass Trivy silently,
suppress whole package families, or relax all media/network gates.

**Remaining gates:** verified source-to-image provenance; published
image integrity/signature or signed and auditable downstream build;
specific CVE remediation + justified treatment of any remaining
findings; user authorizes any documented temporary risk acceptance;
successful backup restore; actual runtime device/direct-play tests.
Public route and Polyfin admission remain OFF.

## Outstanding security evidence for v0.50.0

- Preserve the **exact Trivy JSON** from the pinned OCI index and the
  `linux/amd64` workload image; list all HIGH/CRITICAL IDs, component, installed
  and fixed version, Debian/Go/FFmpeg origin, exploitability and reachability.
  A count of 6 HIGH alone is not enough to choose a safe remediation.
- Upstream `v0.50.0` uses `docker/build-push-action` with
  `provenance: mode=max` and `sbom: true` in
  `.github/workflows/ci.yml`, but has no Cosign signing step there.
  BuildKit **unsigned** provenance and SBOM are useful to audit but are not
  equivalent to a verified publisher signature. Confirm the OCI attestations
  refer to the pinned digest and repository/commit; never claim Cosign PASS.
- Prefer an upstream patched and signed release. If unavailable, consider a
  separately reviewed, **reproducible minimal downstream image rebuild** from
  the exact tagged source with patched dependencies, Trivy/SBOM/provenance,
  user-controlled signing and a pinned immutable digest. It is an explicit
  maintenance trade-off, NOT permission to turn off the admission gate.
- This draft's CI does not run the security gate or prove runtime. Keep Argo
  Polyfin admission OFF until the candidate image passes the approved policy.
- `polyfin-db` now declares `spec.plugins` with `isWALArchiver: true`, bound to
  `polyfin-hetzner-store`. Verify that the Barman CNPG-I operator exists in the
  cluster and inspect WAL archival status, a successful backup AND a restore
  before reporting backup operational.
- The configured AIOStreams HTTPS manifest uses split DNS / internal Gateway
  `10.0.20.192:443`; direct Pod-to-Pod access to `aiostreams:3000`
  is not allowed by AIOStreams ingress. Test Cilium VIP hairpin at runtime.

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
