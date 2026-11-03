# Polyfin 0.59: Authentik OIDC admission and upgrade

Status: staged; not a production configuration. The upstream image is held in
`k8s/optional/polyfin-v059/`, separate from the active signed 0.50.0 private
pilot. Its CVE waiver is digest-bound and MUST NOT be inherited.

References:
- https://github.com/moodiness/polyfin/blob/v0.59.0/docs/administration.md#identity-provider
- https://github.com/moodiness/polyfin/blob/v0.59.0/docs/users.md#signing-in-with-an-identity-provider

## Registration (declarative Authentik half)

The candidate Authentik blueprint and ESO contract are in
`k8s/optional/polyfin-v059/authentik-*.staged.yaml` and are NOT imported.
Register an authorization-code confidential client in Authentik:
- Application slug `polyfin`; OIDC issuer (default per-app mode):
  `https://auth.smadja.dev/application/o/polyfin/`.
- Client ID `polyfin`; single exact callback
  `https://media.smadja.dev/admin/api/provider/callback`.
- Scope mapping `openid profile email groups`. Constrain access to
  `family` and `authentik-admins`; never map family users to admin.
- Secret `APP_POLYFIN_OIDC_CLIENT_SECRET` in Doppler is required before
  importing and must be injected into Authentik's blueprint worker as
  `POLYFIN_OIDC_CLIENT_SECRET`; do not publish its value in Git.
- Keep `POLYFIN_SECRET_KEY` with CNPG backups: it encrypts OIDC client
  secret and provider API keys at rest. Never rotate it casually.

## Polyfin half (upstream admin UI, not environment variables)

Upstream 0.59 stores OIDC provider settings in PostgreSQL. Do not claim that
adding a Kubernetes OIDC_CLIENT_ID environment variable activates it.

1. Restore an exact disposable copy of 0.50's database and prove it passes
   the 0.59 migration, then back up the production database before rollout.
2. In **Settings > Notifications**, set **Public address** to
   `https://media.smadja.dev`; keep this internal-only until admission.
3. In **Settings > Security > Identity provider**, set exact issuer above,
   client ID `polyfin`, confidential client secret, button label
   `Authentik`, user claim `preferred_username`, create accounts only
   after mapping checks, and admin claim/groups restricted to
   `authentik-admins` (never infer admin from email alone).
4. Confirm discovery and exact redirect match; login on
   `/admin/` and `/web/`, using an existing member and a newly-created
   family account. Check user isolation, library permissions, logout,
   forced revoke and Quick Connect on official Jellyfin apps.
5. Validate AIOStreams/Stremio/Eclipse egress and browser CDNs independently:
   the private 0.50 Cilium allowlist currently blocks unknown hosts. Never
   add `world:443` to make OIDC or media playback appear green.
6. Verify the client session and playback state after upgrade, and test DB
   restore before admitting the new OCI digest and HTTPRoute.
7. Preserve an independent local admin breakglass account through OIDC
   testing. Do not expose `Gateway/external` as part of this migration.

Version-specific tests MUST distinguish STATIC, RECONCILED, RUNTIME and USER.
