# PLT-135 — Stage 1: public Polyfin canary on media.smadja.dev

This is **a DRAFT migration candidate, not an authorization to expose Polyfin**.

## Existing topology (2026-11-07)
- AIOStreams family player: public \`tv.smadja.dev\` → \`gateway/external\` → AIOStreams; this must keep working in Stage 1.
- AIOStreams control manifest: private \`aiostreams.smadja.dev\` → \`gateway/internal\` → AIOStreams.
- Polyfin: private \`media.smadja.dev\` → \`gateway/internal\` → Polyfin; real LAN HTTP 200 at Cilium VIP \`10.0.20.192\`, but Brave chooses public Cloudflare AAAA/HTTPS and receives QUIC/reset.
- Authentik Polyfin OIDC callback is currently \`https://media.smadja.dev/admin/api/provider/callback\`.
- Cloudflare already routes \`*.smadja.dev\` to the existing external Gateway. No new tunnel, wildcard or DNS public records are needed.
- The active workload image is official \`ghcr.io/moodiness/polyfin:0.61.1\` with a historical **PRIVATE-only T2 acceptance**, and the old pilot contract still says its route is disabled. **Passing the static private gate does not authorize public exposure.**

## Stage 1 proposal (this PR, unmerged)
- Add the \`external\` parent to active \`k8s/applications/media/polyfin-media-route.yaml\` while keeping \`internal\`, hostname \`media.smadja.dev\` only.
- Add an exact second Authentik redirect URI \`https://tv.smadja.dev/admin/api/provider/callback\`; do not change the current launch URL or remove the \`media\` callback.
- No change to \`tv.smadja.dev\` ownership, AIOStreams, TorBox, media bytes, Nebula or routes inside the Polyfin historical pilot Kustomization.
- Add \`tests/harness/polyfin-tv-migration-contract-test.sh\`, invoked by required \`v1-contract\`, enforcing mutually exclusive Stage 1 and Stage 2 route ownership.

## Mandatory GO/NO-GO before promoting this PR

**This is an Internet exposure change with a wider threat model. Do not silently treat the private-pilot image risk waiver as public approval.**

1. Security owner explicitly requalifies the **exact official Polyfin digest** for public reachability. Reassess previously accepted HIGH/CRITICAL CVEs, available fixed upstream release, exposed routes (including admin API, streaming and DLNA), authentication/authorization, rate limits, brute-force boundaries, known proxy chain, CSRF/CORS and sensible Cloudflare edge controls. Keep existing branch protections, normal PR review and evidence in Linear. If this cannot pass: **NO-GO; leave PR Draft and keep private route**.
2. Verify the \`media.smadja.dev\` external HTTPRoute Accepted/ResolvedRefs after controlled GitOps sync, external TLS/Host/forwarded headers, HTTP /healthz and /admin, WebSockets \`/socket\`, OIDC callback exactness, authenticated family role, unauthenticated denial of protected data, and native Jellyfin client connection. Do not log tokens.
3. Confirm a movie, series and anime playback from an Internet client uses direct CDN bytes (302/Range/network capture) and not an unintended Polyfin/Tunnel video relay; if conversion/proxy is needed, identify reason and decide NO-GO for that client. Radio audio may traverse Cloudflare only with measured volume and permitted terms.
4. Verify LAN access with the private VIP and cloud outage (where feasible). This **does not fix general split DNS**; PLT-149 owns AAAA/HTTPS/SVCB NODATA. The public route merely makes public-path fallthrough work.
5. Cloudflare and Cilium observations must prove no accidental public AIOStreams control API exposure and no permissions broadened. Existing \`aiostreams.smadja.dev\` internal route remains internal-only. Verify that existing external AIOStreams family route still works for current users until Stage 2.
6. Check recovery: revert exactly this PR to remove Polyfin from external Gateway and remove second redirect URI; no database/PVC or OIDC user migration. Confirm \`tv.smadja.dev\` still reaches AIOStreams.

## Stage 2 (separate Draft PR based on this branch)
Once Stage 1 public canary is **GO**, switch \`tv.smadja.dev\` to Polyfin in one coordinated GitOps change:
- Polyfin's active HTTPRoute accepts both \`media.smadja.dev\` and \`tv.smadja.dev\` on **internal and external**.
- Remove AIOStreams' public family HTTPRoute from its active Kustomization; retain only its private \`aiostreams.smadja.dev\` route.
- Change Authentik Polyfin launch URL to \`https://tv.smadja.dev\`. Keep **both** exact callback URIs until client migration is complete.
- Requalify every client endpoint, OAuth callback, invite link (Polyfin's **Public address** native setting), family accounts, CDN delivery and ability to roll back without breaking users.
- Do NOT assume adding the new Authentik blueprint callback changes the Polyfin OIDC provider configuration stored in its DB; inspect actual login redirect from \`tv.smadja.dev\`.

### Follow-up after hostname migration
- Merge qualified static Eclipse Radio France PR #1044; install its catalogue, test live FIP >=5 min; no Worker.
- Clean up duplicate AIOStreams *libraries* only; keep the video source and Nebula.
- Qualify dedicated Anime library and Known Proxies against the real Envoy IP (avoid trusting Pod CIDR).
- PLT-149 fixes LAN split-DNS globally rather than patching each app separately.

## Operator evidence matrix
\`PUBLIC_IMAGE_ADMISSION\`, \`CLOUDFLARE_EDGE_ROUTE\`, \`MEDIA_EXTERNAL_HTTPS\`, \`MEDIA_OIDC_FAMILY\`, \`MEDIA_OIDC_ADMIN\`, \`DENY_UNAUTH_DATA\`, \`WEBSOCKET\`, \`DIRECT_CDN_VIDEO\`, \`LAN_PATH\`, \`AIOSTREAMS_UNCHANGED\`, \`ROLLBACK\`.

**Never claim PUBLIC=PASS because only HTTPRoute is Accepted or a 200 healthcheck succeeds.**
