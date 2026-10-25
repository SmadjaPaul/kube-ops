# AIOStreams v2.37.0 — family control plane (STAGED, not deployed)

**No Media root import in this PR.** The application does not exist in cluster
unless a subsequent, reviewed PR adds `- aiostreams` to
`k8s/applications/media/kustomization.yaml`.

## Non-negotiable architecture

- Only catalogue, Stremio/Jellyfin-compatible control APIs, account dashboard,
  metadata and subtitle requests may flow through the Cloudflare/Gateway route
  `https://aiostreams.smadja.dev`.
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
- OIDC is OFF until Authentik provider registration and post-bootstrap checks.
  It protects the *admin/configure* experience, **not** Smart-TV/Quick Connect.
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
4. Enable Media root in a **separate** PR after successful review and
   explicit source-of-truth check. No manual kubectl apply.
5. Native AIOStreams: first operator login; create first config through UI,
   selected addon and TorBox credentials approved by vendor account policy.
6. Prove two independent profiles, no cross-user history leakage, TV login
   where supported, basic functionality before distributing any invite.
7. Capture **redacted network proof**: actual playback URL hostname, TLS
   destination/IP, home ingress bytes, gateway and Cloudflare logs: no
   media bytes via Cloudflare/AIOStreams, including HLS/range requests,
   subtitles, thumbnails and transcoding fallback. Reject if ambiguous.
8. OIDC follow-up after provider setup + local fallback verified;
   no unsupported promise of TV SSO.
9. Confirm written TorBox multi-household rights; do not share one API key
   among households absent vendor authorization.

Public references:
- https://github.com/Viren070/AIOStreams/releases/tag/v2.37.0
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/compose.yaml
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/packages/docs/content/docs/configuration/environment-variables.mdx
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/packages/docs/content/docs/getting-started/deployment.mdx
