# ESS Community Matrix

This package deploys Element Synapse, Matrix Authentication Service (MAS) and
Element Web as one isolated ESS Community release.

## Immutable decisions

- Matrix `server_name`: `smadja.dev`.
- Synapse: `https://matrix.smadja.dev`.
- Element Web: `https://chat.smadja.dev`.
- MAS account service: `https://account.smadja.dev`.
- Authentik issuer: `https://auth.smadja.dev/application/o/matrix-mas/`.
- MAS provider id: `01HFRQFT5QFMJFGF01P7JAV2ME` (stable ULID).
- ESS chart: `oci://ghcr.io/element-hq/ess-helm/matrix-stack:26.10.2`.
  OCI digest observed during design validation:
  `sha256:3597302e27d4eaeaf22dc23777f845f1b0b6d78192544bafda29618c991495ab`.

The server name is embedded in Matrix user and room IDs and must not be
changed after the first deployment.

## External prerequisites

1. Create the Authentik confidential OAuth2 provider/application with slug
   `matrix-mas`, scopes `openid profile email`, and exact redirect URI:
   `https://account.smadja.dev/upstream/callback/01HFRQFT5QFMJFGF01P7JAV2ME`.
   Do not configure the legacy Synapse callback.
   Access is restricted to Authentik groups `family` and
   `authentik-admins`; accounts outside those groups must be denied.
2. Provision Doppler keys
   `APP_MATRIX_MAS_AUTHENTIK_OIDC_CLIENT_ID` and
   `APP_MATRIX_MAS_AUTHENTIK_OIDC_CLIENT_SECRET`. The same pair is consumed
   by the Authentik blueprint and the MAS ESO template.
3. Provision DNS/Cloudflare/tunnel records for `matrix`, `chat` and
   `account` in `homelab-infra`; the apex `smadja.dev` must serve Matrix
   `.well-known` through the Gateway.
4. Provision the Matrix bot credentials in Doppler only after the ESS rollout:
   `APP_MATRIX_FACTORY_BOT_ACCESS_TOKEN`,
   `APP_MATRIX_FACTORY_OPS_ROOM_ID`, and optionally
   `APP_MATRIX_PUBLIC_ANNOUNCEMENTS_ROOM_ID`.
5. Create `@factory-notifier:smadja.dev` and a restricted, invite-only,
   non-E2EE `#factory-ops` room. E2EE is intentionally deferred until bot
   device/key recovery has been proven.

Factory's Matrix adapter is enabled only by the reviewed GitOps deployment
change after the bot, private room and ESO checks pass. This package does not
enable public publishing, inbound commands or merge/deploy capability.

## Evidence gates

Static render/schema checks are required before Argo reconciliation. Runtime
proof must separately cover Argo sync, both CNPG clusters and backups, media
PVC binding/offsite coverage, Gateway/DNS/TLS, `.well-known`, MAS OIDC login,
Element Web, and a real authenticated Factory operator smoke. This README does
not claim any of those runtime or user-level checks before they execute.
