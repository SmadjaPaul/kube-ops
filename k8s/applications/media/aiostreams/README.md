# AIOStreams v2.37.0 — family control plane (PRIVATE ADMISSION)

This admission adds the package to the Media root with an internal-only
`Gateway/internal` route. It does not add a public Gateway parent, Cloudflare
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

## Gates to deploy

1. Resolve image digest and validate exact image behaviour, licensing,
   database SQLite storage and persistence (incl. backup/restore).
2. Create only two secret values in Doppler without logging: cryptographic
   AIOSTREAMS_SECRET_KEY and high-entropy OPERATOR_AUTH; ESO Ready.
3. Render and run existing GitOps CI; single-pod ingress/egress tests.
4. Media root import has already been admitted by PR #740; this canary
   is internal-only and blocked until ESO bootstrap becomes Ready. Keep
   OIDC and public exposure separately gated. No manual kubectl apply.
5. Native AIOStreams: first operator login; create first config through UI,
   selected addon and TorBox credentials approved by vendor account policy.
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
- The active policy permits DNS and the Authentik issuer only. It intentionally has no `world:443` rule.
  A later admission PR must add Cilium `toFQDNs` from a reviewed matrix, not a
  guess: the upstream image has built-in metadata hosts such as
  `v3-cinemeta.strem.io` and `skyhook.sonarr.tv`, TorBox search uses
  `search-api.torbox.app`, OIDC would use `auth.smadja.dev`, and user-selected
  addons/indexers/debrid services add their own hostnames. The manifests in this
  PR select none of those, so no external FQDN is currently authorized.
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
`authentik-admins` group. The workload currently has OIDC disabled and its
ExternalSecret intentionally contains only `APP_AIOSTREAMS_SECRET_KEY` and
`APP_AIOSTREAMS_OPERATOR_AUTH`. Do not add the OIDC secret or admit the
blueprint until local login, provider discovery, exact claims, empty default
permissions and local-login fallback are tested without printing secret values.

## Runtime qualification for PLT-121

- The admitted `networkpolicy.yaml` allows only UDP/TCP 53 to CoreDNS. All other
  pod egress is refused, including TCP 443. This is intentional for this
  control-plane-only admission; it is not an external-addon functionality
  policy.
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
- The checked-in SQLite harness proves only synthetic `.backup`/`.restore`,
  `integrity_check` and sentinel preservation. A real isolated drill must
  quiesce the single writer, include WAL state, restore to a new PVC with the
  same `SECRET_KEY`, run migrations and verify a synthetic login/config
  sentinel. No production PVC may be deleted or reinitialized.
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
