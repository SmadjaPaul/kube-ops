# Polyfin — family media pilot (private LAN/VPN)

Status: **PRIVATE PILOT ADMITTED / PENDING ARGO RECONCILIATION**. The parent
media Kustomization enables this folder only through the reviewed PR #781.
There is no external HTTPRoute or Cloudflare Tunnel.

The temporary risk acceptance is machine-checked by
`.github/polyfin/private-pilot-admission.json` and
`scripts/polyfin-admission-check.sh`. It is bound to the exact signed
downstream digest, linux/amd64, the internal Gateway, and expires at
`2026-11-26T23:59:59Z`. It accepts only the 17 CVEs in that file; a new CVE,
digest, platform or perimeter change fails admission. `CVE-2026-6653` remains
an individual CRITICAL entry and is not hidden from Trivy.

Current admission result (2026-10-27): the signed downstream `0.50.0` candidate
is pinned by immutable digest. A reproducible Trivy 0.76.1 scan of
`linux/amd64` on workflow run
[`40558560121`](https://github.com/SmadjaPaul/kube-ops/actions/runs/40558560121)
reports **61 HIGH/CRITICAL affected-package occurrences, 23 distinct CVEs,
including one CRITICAL**; six distinct CVEs have published fixes. The original
operator scan reported six HIGH, apparently using a narrower or
fixed-vulnerabilities-only filter: its exact command needs comparison.
Do not confuse the number of package occurrences with distinct CVEs.
The downstream Cosign signature, SBOM and provenance were independently
verified. The whole Trivy JSON and TSV are attached as GitHub Actions artifact
`polyfin-downstream-candidate-01dfcfa30e78aaf6f28115180d8c90fb61cfc334`.

## Historical upstream vulnerability baseline — 2026-10-27

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

The minimal downstream patch is recorded in
`.github/polyfin/Dockerfile.v0.50.0.patch` and applies only to the exact
upstream commit `e2cf9f08ac60400fdab20726671fa2e08fd09e1e`. The manual
workflow `.github/workflows/polyfin-downstream-build.yaml` rebuilds that
source for `linux/amd64`, emits an SPDX SBOM and BuildKit/GitHub provenance,
signs and verifies the immutable digest with Cosign, then rescans it. It
publishes evidence but fails closed while any HIGH/CRITICAL finding remains;
it does not change the Polyfin deployment image.

## Approved downstream candidate

The approved private-pilot image is:

`ghcr.io/smadjapaul/polyfin-downstream:0.50.0-patched-01dfcfa30e78-run40564826453-attempt1@sha256:0b05483c047bb904dfcb8c4e893c528223833c7903ae8f193b4f31475ad5eaf3`

Its exact `linux/amd64` Trivy result is 54 HIGH/CRITICAL occurrences across
17 residual CVEs after the six correctable CVEs were eliminated. The full
candidate evidence is the GitHub Actions artifact
`polyfin-downstream-candidate-01dfcfa30e78aaf6f28115180d8c90fb61cfc334` from
workflow run 40564826453. Cosign identity, GitHub SLSA provenance and the
SPDX SBOM are recorded in the PR evidence. The admission policy does not
hide these findings; it only authorizes this exact digest until its expiry.

**Other findings:** 17 remaining unique Debian CVEs have no fixed-version
entry in the scanner, including Trivy **CRITICAL `CVE-2026-6653`**
(`libxml2`, a malformed-XML denial-of-service scenario). Debian's
Trixie tracker describes it as `no-dsa` / minor; that is *not* a
proof of non-reachability in Polyfin, especially with XMLTV, image
processing, subtitles and FFmpeg/Tesseract dependencies. Need concrete
runtime linkage and reachable-input analysis before considering any
limited internal-pilot risk acceptance. Never bypass Trivy silently,
suppress whole package families, or relax all media/network gates.

### Residual CVE reachability assessment

This is a reachability review, not a waiver. The local downstream image was
built for `linux/amd64`; `/polyfin` is a static Go binary, while FFmpeg and
Tesseract are separate child processes. The container runs as UID 65532 with a
readonly root filesystem and no extra capabilities.

| CVE group | Component(s) | Evidence from the image/application | Disposition |
| --- | --- | --- | --- |
| `CVE-2025-69720` | ncurses / `libtinfo6` | `infocmp` is present but Polyfin does not invoke it; network input cannot reach that CLI directly. | Residual, no waiver |
| `CVE-2026-16742` | systemd / `libsystemd0`, `libudev1` | No systemd init or `systemd-homed` service is started; Polyfin is nonroot. | Residual, no waiver |
| `CVE-2026-54369` | `libacl1` | Loaded transitively by the optional Tesseract toolchain; no evidence that Polyfin reaches the vulnerable ACL pathname APIs. | Residual, runtime/vendor proof required |
| `CVE-2026-6653`, `74860`, `86138`, `86139`, `86140`, `86142`, `86143`, `86144` | `libxml2` | Tesseract's native dependency tree loads `libxml2`; Polyfin's own XML decoding uses Go `encoding/xml`. XMLTV and subtitle inputs are potentially untrusted, but the vulnerable libxml2 call paths were not proven. | **CRITICAL/HIGH residual, blocks admission** |
| `CVE-2026-76642`, `78408`, `78409`, `78410` | util-linux | `mount`/`nsenter` are present as base-image helpers but are not invoked by Polyfin; UID 65532 has no mount capability. | Residual, no waiver |
| `CVE-2026-88806` | libX11 | Present through optional graphics dependencies; no X server is configured and baseline FFmpeg linkage does not load it. | Residual, optional GPU path proof required |
| `CVE-2026-9538` | `perl-base` | Perl is present in the base image but is not an application entrypoint or child process. | Residual, no waiver |

Debian records several of these as Trixie `no-dsa`/minor while fixing them in
unstable, including [ncurses](https://security-tracker.debian.org/tracker/CVE-2025-69720),
[util-linux](https://security-tracker.debian.org/tracker/CVE-2026-76642) and
[libxml2](https://security-tracker.debian.org/tracker/CVE-2026-6653). That is a
vendor prioritization, not evidence that the vulnerable code is unreachable in
this application. No temporary exception is applied automatically.

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

## AIOStreams endpoint: scoped DNS correction (27 October 2026)

The existing Polyfin egress policy permits exactly `10.0.20.192:443`
for HTTPS access to the AIOStreams manifest. The configured manifest uses
`https://aiostreams.smadja.dev/…/manifest.json`, but public Cloudflare
AAAA DNS answers can cause a Pod to select an unreachable external IPv6
address instead of the internal Cilium Gateway.

The Deployment now sets a **Pod-scoped Kubernetes `hostAliases` entry**:
`aiostreams.smadja.dev → 10.0.20.192`. This does not affect other Pods
or public DNS; TLS continues to validate the original hostname/SNI.
No new egress or public route is added. The trade-off is an explicit
coupling to the cluster's internal Gateway VIP: keep this entry synchronized
if the VIP changes, and prefer a proven centralized split-DNS design if the
same issue arises repeatedly across workloads.

**Runtime acceptance (NOT EXECUTED by this GitOps patch):**
1. Confirm the internal AIOStreams HTTPRoute is `Accepted=True` and
   presents the expected TLS certificate on `10.0.20.192:443`.
2. After reconciliation, verify Polyfin Pod `/etc/hosts` maps the exact
   hostname to the Gateway VIP; don't print the configured manifest path.
3. Fetch the **already-configured** AIOStreams manifest from inside the
   Polyfin network namespace with the existing confidential URL. Assert
   HTTP 200, `Content-Type: application/json`, and JSON manifest fields
   `id/name/version/resources`, without exposing its UUID/token.
4. Confirm Hubble shows allowed traffic only to `10.0.20.192:443` and
   no Cloudflare IPv6. Ensure the AIOStreams Pod sees the normal Gateway
   ingress, without expanding ingress rules.
5. Reuse the server-wide AIOStreams source in Polyfin; test one public
   metadata catalog and a title's stream descriptors. Direct CDN playback
   still requires separate client-side evidence, not a server-side relay.
6. If Cloudflare still appears, inspect the exact resolver and HTTP client
   behavior rather than adding `world:443`. Restore the previous
   Deployment if this workaround fails.
7. AIOMetadata `invalid_manifest` is a distinct case: inspect the
   **sanitized response** of its real `/manifest.json` for required
   fields. Never invent an API URL, replace the upstream addon with a
   fake manifest, or leak query/path authentication data.

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

## Authentik OIDC status — explicitly blocked upstream

Polyfin SSO is **not configured**. This is intentional: upstream issue
[#217](https://github.com/moodiness/polyfin/issues/217) remains open in the
`Later` milestone, with no linked implementation branch or pull request. The
latest released Polyfin version used by this pilot is `0.50.0`; upstream's
current Silo capability contract still advertises both OAuth and external sign
in as unsupported, and the deployed web login remains the native username /
password flow.

Do not add an Authentik provider, client secret, callback URL, Cilium egress
exception or web-only button until Polyfin has a real server-side callback.
There is no valid redirect URI to register today. An Authentik reverse-proxy
outpost would only front the page and would not create a Polyfin/Jellyfin
session, so it is not an acceptable substitute.

The minimum maintainable implementation belongs upstream and must be treated
as a new Polyfin image, not as a Kubernetes overlay. It requires:

1. server-side Authorization Code + PKCE routes with `state`, `nonce`, one-use
   expiry and replay protection;
2. discovery/JWKS validation with exact issuer, audience and expiration checks;
3. an encrypted provider configuration and a stable `(issuer, sub)` identity
   table, with explicit linking of the existing administrator and a local
   break-glass account;
4. creation of a normal Polyfin/Jellyfin session, logout and revocation
   semantics, plus authorization/group mapping;
5. web and admin-client integration, Quick Connect compatibility and tests for
   denied groups, account isolation and session invalidation; and
6. a new signed image with SBOM, provenance, vulnerability scan and a new
   immutable admission record. The current temporary CVE acceptance is bound
   to the existing digest and must not transfer to that image.

Until those upstream contracts exist and a real end-to-end login is proven,
the acceptance state is `OIDC=NOT_EXECUTED`, while native Polyfin login and
Quick Connect remain unchanged. No Authentik secret is read or added by this
pilot.

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
