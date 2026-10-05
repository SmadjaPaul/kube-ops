# Sure — staged V1 replacement for Actual Budget

This directory is intentionally **not referenced by the catalog root yet**.
It is a staged manifest set for Sure `v0.7.5-hotfix.2`.

Activation gates:

1. Provision Doppler keys without printing values:
   - `APP_SURE_SECRET_KEY_BASE`
   - `APP_SURE_OAUTH_CLIENT_SECRET`
2. Add an Authentik OIDC client:
   - client id: `sure`
   - issuer: `https://auth.smadja.dev/application/o/sure/`
   - redirect: `https://sure.smadja.dev/auth/openid_connect/callback`
   - access policy: `family` and `authentik-admins`
3. Add the Sure Authentik blueprint/ExternalSecret to the active Authentik bundle.
4. Add `sure` to `k8s/applications/catalog/kustomization.yaml`.
5. Let Argo reconcile naturally, then validate OIDC and promote the first human
   account to Sure `super_admin` using an explicitly approved bootstrap procedure.

Design notes:

- Local password login is disabled.
- OIDC JIT creation is enabled; Authentik is the authorization boundary.
- One web pod + one worker pod + one ephemeral Valkey pod + one CNPG instance.
- The 5Gi `/rails/storage` PVC is RWO and intentionally V1/single-node scoped.
- PostgreSQL WAL/base backup uses the existing Hetzner CNPG pattern.
- Sure's built-in AI/MCP integration is not enabled in this first deployment.
