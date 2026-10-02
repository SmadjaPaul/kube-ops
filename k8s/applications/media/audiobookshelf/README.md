# Audiobookshelf authentication contract

Audiobookshelf 2.35.0 does not consume the historical `OIDC_*` environment
variables that were present in this manifest. OIDC settings are persisted in
Audiobookshelf server settings.

The upstream API exposes:

- `GET /api/auth-settings`
- `PATCH /api/auth-settings`

but updating those settings requires an already-authenticated administrator.

V1 bootstrap is therefore:

1. create the first Audiobookshelf administrator once;
2. configure Authentik with these redirect URIs:
   - `https://audiobookshelf.smadja.dev/auth/openid/callback`
   - `https://audiobookshelf.smadja.dev/auth/openid/mobile-redirect`
3. configure OIDC through Audiobookshelf Settings > Authentication, or a later
   idempotent API bootstrap that uses an explicitly-scoped admin token;
4. verify browser and mobile OIDC before enabling auto-launch.

Do not recreate `OIDC_ENABLED`, `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `OIDC_AUTO_LAUNCH`, or `OIDC_AUTO_REGISTER` as pod
environment variables: upstream does not read them.

`external-secret.yaml` is retained as historical/reference material but is
not rendered until a real API/bootstrap consumer exists.
