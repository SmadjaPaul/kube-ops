# AIOStreams v2.37.0 — native video app (PRIVATE ROUTE)

The Media root already deploys AIOStreams with an internal-only
`Gateway/internal` route. There is no public Gateway parent, Cloudflare
route, or blanket external egress.

## Non-negotiable architecture

- Only catalogue, Stremio/Jellyfin-compatible control APIs, account dashboard,
  metadata and subtitle requests may flow through the **internal** Gateway
  at `https://aiostreams.smadja.dev`. Public Cloudflare access is not yet
  admitted and requires a separate review.
- Videos: TorBox HTTPS **directly to each household device**. No AIOStreams
  media proxy, MediaFlow, StremThru proxy, FUSE mount, Jellyfin local proxy or
  Cloudflare-Tunnel video relay. This is a hypothesis until packet/URL E2E passes.
- Reject candidate addons returning AIOStreams, Cloudflare, local IPs or third-
  party relay as the actual video transport. Direct playback failures must
  fail closed, never silently enable a proxy.
- This service is *not* the current Jellyfin Pod; the Jellyfin-compatible API
  serves metadata and stream links only. Do not accidentally route to existing
  `jellyfin.smadja.dev`.

## Upstream-verified startup contract

- Verified version: stable `v2.37.0`, published 2026-10-23.
- Official image: `ghcr.io/viren070/aiostreams:v2.37.0` (must pin digest
  after registry inspection; unpinned tag is a merge blocker).
- Official Docker volume: `/app/data`. SQLite default:
  `sqlite://./data/db.sqlite`; 1 replica with RWO data PVC.
- Required `BASE_URL` and `SECRET_KEY` (64 hex chars, irreversible if
  rotated). Provision `APP_AIOSTREAMS_SECRET_KEY` to `cluster/prd` Doppler.
- Protect operator configuration with `AIOSTREAMS_AUTH`, expressed as
  `user:password` from `APP_AIOSTREAMS_OPERATOR_AUTH` (do not commit value).
  Verify account bootstrap semantics against exact image.
- `AIOSTREAMS_AUTH_REQUIRED=true`, local operator login available.
- `FORCE_PROXY_ENABLED=false` and `DEFAULT_PROXY_ENABLED=false` locked
  overrides. No `DEFAULT_SERVICE_CREDENTIALS` / `FORCED_SERVICE_CREDENTIALS`
  or TorBox master key exposed to ~30 people or in per-user manifests.
- OIDC is active for the private dashboard/configuration route after the
  Authentik provider and post-bootstrap checks. It protects the
  *admin/configure* experience, **not** Smart-TV/Quick Connect.
  Use `AIOSTREAMS_OIDC_DEFAULT_PERMISSIONS` deny-by-default; map group
  `authentik-admins` to admin only in a reviewed follow-up.
- No extra PostgreSQL/Redis, no elevated capability, no port forwarding.
- Cloudflare controls/routes/DNS must be reviewed separately before opening
  the host to external families, especially access control and cache policy.

## Functional gates (after private deployment)

1. Keep the exact pinned OCI digest, non-root runtime and persistent SQLite
   volume. Requalify on image upgrades.
2. Check the **existing** three Doppler/ESO secret names (bootstrap key,
   operator recovery auth and OIDC client secret) for Ready status; never
   inspect or print values.
3. Render GitOps, run contracts, and preserve scoped positive/negative
   ingress/egress tests.
4. Media root import and Authentik OIDC are already active on the internal route;
   admin login, issuer discovery and SQLite backup/restore were runtime-qualified.
   Keep public access gated separately. No manual kubectl apply.
5. The operator has created a personal configuration and supplied TorBox in
   the UI. This is **not** proof that a TorBox source resolves or plays. Use
   the native browser app to qualify the actual catalog/stream path.
6. Prove two independent profiles, no cross-user history leakage, TV login
   where supported, basic functionality before distributing any invite.
7. Capture **redacted network proof**: actual playback URL hostname, TLS
   destination/IP, home ingress bytes, gateway and Cloudflare logs: no
   media bytes via Cloudflare/AIOStreams, including HLS/range requests,
   subtitles, thumbnails and transcoding fallback. Reject if ambiguous.
8. The active Authentik blueprint is at
   `k8s/infrastructure/auth/authentik/extra/blueprints/apps-aiostreams.yaml`
   with the verified `/api/v1/auth/oidc/callback` redirect. The existing
   projection supplies the client secret to Authentik and AIOStreams;
   provider discovery and blueprint status are runtime-qualified. Keep
   `AIOSTREAMS_OIDC_GROUP_PERMISSIONS=authentik-admins=admin`, an empty
   default-permissions mapping, and the local admin fallback. OIDC does not
   provide TV SSO.
9. Confirm written TorBox multi-household rights; do not share one API key
   among households absent vendor authorization.

## Audit evidence and admission blockers

- The admission pins the multi-architecture image index to
  `sha256:bcfd8580695a50c8f464578a0e25af065f3bd17eac35ed82a733a18342ca9718`;
  its Linux/amd64 child manifest is
  `sha256:c1dd8ef7d5db9dbddbf829545e18e9ab6e5eef09ebb705924c9db89729d47dfd`.
  The exact image config declares UID 0, so the pod-level UID/GID 2501,
  `runAsNonRoot`, dropped capabilities and read-only root filesystem are
  mandatory runtime controls. They must be rechecked when the digest changes.
- The exact image exposes `/api/v1/health`; all three probes use that path on
  named port 3000. A local image test confirmed the UID override can write only
  the mounted `/app/data` and `/tmp` paths; it is not cluster or application
  readiness proof.
- The active policy permits DNS, narrowly scoped Authentik issuer access and
  the reviewed metadata/addon/TorBox control-plane FQDN matrix over TCP/443.
  It has no `world:443` rule and does not authorize media/CDN bytes. The
  current matrix covers `api.torbox.app`, `search-api.torbox.app`,
  `v3-cinemeta.strem.io`, `v3.sg.media-imdb.com`, `remuxdb.1632022.xyz`,
  `comet.feels.legal`, `meteorfortheweebs.midnightignite.me`,
  `stremthru.13377001.xyz`, `opensubtitles.stremio.homes` and the selected
  public AIOMetadata instance at `aiometadata.streetle.dev`; additional
  user-selected addons/indexers/debrid services require separately reviewed
  FQDN admission.
- `FORCE_PROXY_ENABLED=false`, `DEFAULT_PROXY_ENABLED=false`, no proxy URL or
  proxy credentials are supplied, and `SHARES_FUSE_ENABLED=false`. This is a
  configuration guard, not proof of no video proxy: the exact upstream image
  still implements `/api/v1/proxy/*` and accepts per-user proxy settings.
  Admission remains blocked until a synthetic, non-production playback test
  records the returned direct URL host and packet/HTTP evidence showing no
  AIOStreams, Gateway or Cloudflare media bytes, including HLS/range,
  subtitles, thumbnails and fallback paths.
- The admitted `HTTPRoute` attaches only to `gateway/internal`. Private
  ExternalDNS therefore derives `aiostreams.smadja.dev` for the UniFi LAN/VPN
  DNS path and points it at the internal Gateway VIP. It is not watched by the
  public ExternalDNS path, and Cloudflare's wildcard/tunnel cannot reach this
  route because it has no `gateway/external` parent. No per-application
  Cloudflare DNS record or tunnel ingress is introduced. This remains an
  internal canary until a separate admission review accepts public access.

## Synthetic SQLite backup/restore qualification

The checked-in `tests/harness/aiostreams-sqlite-restore-test.sh` creates a
temporary SQLite database with a synthetic sentinel, runs SQLite `.backup`,
restores it into a second temporary file, and checks `integrity_check` plus the
sentinel. It never reads a PVC or production data. This qualifies the mechanics
only; it does not claim application recovery.

The eventual isolated drill must use a new namespace, new PVC and synthetic
configuration. Quiesce the AIOStreams writer, create a consistent `.backup`
from `/app/data/db.sqlite` (including any WAL state), restore into the new PVC,
run the exact image with the same `SECRET_KEY`, check migrations and the health
probe, then verify a synthetic login/config sentinel. Never delete or
reinitialize the production PVC. Record source/backup/restore timestamps,
SQLite integrity output, image digest and the isolated namespace in the test
result; destroy only the isolated drill resources after evidence is retained.

## Authentik and secret contract

The Authentik blueprint is included in the active blueprint bundle. Its
strict callback is
`https://aiostreams.smadja.dev/api/v1/auth/oidc/callback`; it consumes the
environment-backed `AIOSTREAMS_CLIENT_SECRET` and grants only the existing
`authentik-admins` group. The base `deployment.yaml` still declares OIDC
`false`, but the **active** `oidc-deployment-patch.dormant.yaml` overrides it to
`true`, with the additional active `aiostreams-oidc` ExternalSecret. The `.dormant`
suffix is a legacy filename, not the resource state. Admin SSO, issuer discovery
and the local fallback login were qualified; recheck after auth changes without
logging secrets. OIDC does not provision playback profiles.

## Native AIOStreams web app — selected user experience

The end-user UI is the **native AIOStreams app**, not Stremio Web. From the
existing personal configuration, select **Save & Install → AIOStreams app →
Open in browser**. See https://docs.aiostreams.viren070.me/apps/.
The operator's Authentik OIDC login does not provision a playback profile:
qualify the separate sign-in, PIN, isolation and TV Quick Connect.

`/stremio/*` provides AIOStreams' still-used addon and manifest protocol.
It is **not dead Stremio client code** and must remain even if Stremio Web is
not offered. No Stremio client workload is imported into the Media root.

AIOMetadata is optional as an upstream **Custom Addon**; it is not a required
Kubernetes service. Upstream warns that nesting its stable manifest behind
AIOStreams adds a hop and caching: qualify metadata freshness and catalog
refresh on changes. Never expose per-user manifest URLs in logs.

A usable video release requires a non-admin playback profile, metadata results,
an authorized TorBox/CDN stream actually playing on the client, and observed
network proof that no media bytes cross AIOStreams, Gateway or Cloudflare.
Additional egress requires observed addon/API FQDNs, never `world:443` or a proxy.
The current candidate allowlist does **not** qualify runtime E2E; check
Cilium/Hubble positive and negative flows after GitOps reconciliation.

## Runtime qualification for PLT-121

- Active egress allows CoreDNS, narrowly scoped Authentik issuer access and
  the reviewed control-plane hosts over HTTPS: `api.torbox.app`,
  `search-api.torbox.app`, `v3-cinemeta.strem.io`, `v3.sg.media-imdb.com`,
  `remuxdb.1632022.xyz`, `comet.feels.legal`,
  `meteorfortheweebs.midnightignite.me`, `stremthru.13377001.xyz`,
  `opensubtitles.stremio.homes` and `aiometadata.streetle.dev`. These are
  control-plane dependencies only;
  no CDN/media egress is granted to the Pod.
- Upstream v2.37.0 has these baseline outbound dependencies when its default
  metadata and mapping features run: `v3.sg.media-imdb.com`,
  `v3-cinemeta.strem.io`, `skyhook.sonarr.tv`, `raw.githubusercontent.com`,
  `github.com` (release-hosted mapping datasets), and `services.sonarr.tv`.
  `search-api.torbox.app` is conditional on selecting
  the TorBox Search addon. `stremthru.13377001.xyz` is conditional on using the
  built-in StremThru/debrid path. OIDC adds the configured issuer, expected to
  be `auth.smadja.dev` for this deployment. User-selected addons, indexers,
  debrid services and direct media URLs are not statically enumerable and must
  be an explicit, reviewed FQDN matrix; never replace this with `world:443`.
- Direct video remains a client-side requirement. The pod must not receive
  TorBox media bytes, and the upstream image still exposes `/api/v1/proxy/*`;
  the two proxy environment overrides are guards, not proof. Admission needs
  redacted URL and packet/HTTP evidence for direct playback, HLS/range,
  subtitles, thumbnails and fallback paths.
- The synthetic SQLite harness proves DB mechanics. Separately, the completed
  Velero backup `aiostreams-qual-20261026` captured the real data PVC and an
  isolated restore passed SQLite `integrity_check=ok` (PR #759). This is volume
  backup/restore proof, **not** a full authenticated app recovery test. Never
  delete or reinitialize the source PVC.
- `apps-aiostreams.yaml` is in the active Authentik bundle. The runtime
  provider discovery returned the per-provider issuer, and the deployment
  keeps `AIOSTREAMS_OIDC_SCOPES=openid profile email groups`, an empty default
  permissions mapping, only `authentik-admins=admin`, and the local-login
  fallback. OIDC protects dashboard/configuration access; it is not
  TV/Quick Connect SSO. User-level isolation and non-admin denial remain
  explicit browser-test gates.
- The current `http-route.yaml` is internal-only, and the Media root DOES
  already import this application. Keep the external parent absent until
  access-control, Cloudflare and direct-video evidence are accepted.

Public references:
- https://github.com/Viren070/AIOStreams/releases/tag/v2.37.0
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/compose.yaml
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/packages/docs/content/docs/configuration/environment-variables.mdx
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/packages/docs/content/docs/getting-started/deployment.mdx
