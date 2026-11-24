# Synthetic test accounts for agents (PLT-57)

An agent creates its own synthetic Authentik users for end-to-end tests and deletes them afterwards. No human account,
no real data, no Authentik admin credential.

## Identity

| Item | Value |
|---|---|
| Service account | `agent-e2e` (type `service_account`, not superuser), blueprint `k8s/infrastructure/auth/authentik/extra/blueprints/qa-agent-e2e.yaml` |
| Token | Doppler `cluster/prd` key `APP_AGENT_E2E_TOKEN` (also read by the ExternalSecret `authentik-blueprint-core-secrets`) |
| Role | `agent-e2e-user-manager`, attached to the `agent-e2e` user (not to the `test-users` group) |
| Global permissions | `authentik_core.add_user`; `authentik_core.view_group` (read-only, to resolve the group UUIDs) |
| Per-object permissions | `view_user`, `delete_user`, `reset_user_password` on each user created by a holder of the role (initial permissions `agent-e2e-created-users`) |
| Not granted | superuser, any group/role/flow/application/provider/token permission, any right on pre-existing users |

`doppler-safe.sh` does not read `cluster/prd` by default (`infrastructure/prd`); the key is only in `cluster/prd`. Only the pairs `infrastructure/prd`, `cluster/prd` and `apps/prd` are accepted.

## Use the token without reading it

```bash
bash scripts/agent-e2e-run.sh -- python3 -I your-e2e-script.py
```

The script runs the command under `doppler-safe.sh run --only APP_AGENT_E2E_TOKEN -p cluster -c prd`, drops every other variable and exposes the
value only as `AGENT_E2E_TOKEN` (output is masked). Never print it, never write it to a file.

## Rules for the test users

- Authentik decides detail routes per object: keep the `pk` returned at creation and use `GET/DELETE/set_password` on `/core/users/{pk}/`. The user list is 403 (no global `view_user`); verify deletion with a detail `GET` returning 404.
- Calls to `auth.smadja.dev` pass through Cloudflare: send a `User-Agent` (the default Python one gets error 1010).
- Username prefix `agent-e2e-`, `type=internal`, groups exactly `test-users` and `family` (apps authorize `family`).
  Authentik only refuses superuser groups on creation: do not pass any other group.
- Password: random, generated in memory, set with `POST /api/v3/core/users/{pk}/set_password/`, never printed or committed.
- No real data. Delete the users at the end (`DELETE /api/v3/core/users/{pk}/`) and verify with a detail GET (404) that
  every created pk is gone. Application-side accounts created by first OIDC login are removed in each app.

## Application provisioning (checked in Git, 2026-11-15)

| App | First OIDC login creates the account? | Evidence |
|---|---|---|
| Mealie | Yes (static): `OIDC_SIGNUP_ENABLED=true`, `OIDC_USER_GROUP=family` | `k8s/applications/catalog/mealie/deployment.yaml`; runtime NOT_TESTED |
| Immich | Yes (static): `oauth.autoRegister: true` | `k8s/applications/media/immich/immich-server/immich-config-external-secret.yaml`; runtime NOT_TESTED |
| Vikunja | Yes (static): OpenID provider `authentik` enabled, upstream creates the user on first login | `k8s/applications/catalog/vikunja/deployment.yaml`; runtime NOT_TESTED |
| Polyfin (media) | No: `create_accounts = false` (`polyfin_identity_provider`, homelab-infra#784). Pre-create the Polyfin account (`POST /admin/api/users`, `providerOnly: true`, no password) then `PATCH` `providerLinkAllowed: true`; the next Authentik sign-in under that name links it. Delete it afterwards (`DELETE /admin/api/users/{id}`). RUNTIME 2026-11-24 (PRD-86) | `k8s/applications/media/polyfin/README.md`, section "Authentik OIDC status" |
| Actual Budget | Not deployed (removed earlier) | no manifest |
| Paperless | No: no OIDC setting in `k8s/applications/catalog/paperless/app.yaml`; Authentik provider exists | BLOCKED until Paperless gets `PAPERLESS_APPS` / `PAPERLESS_SOCIALACCOUNT_PROVIDERS` |
| Trilium | No: no OIDC setting in `k8s/applications/web/trilium/deployment.yaml`; no Authentik provider | BLOCKED |
