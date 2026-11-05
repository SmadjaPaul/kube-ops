# RomM 5.2.0 — fix family OIDC role (PLT-136)

## Root cause verified against the **deployed version**

The GitOps manifest deploys `ghcr.io/rommapp/romm:5.2.0`.
Its previous environment was:

```text
OIDC_CLAIM_ROLES=groups
OIDC_ROLE_VIEWER=family,media
OIDC_ROLE_ADMIN=authentik-admins
```

In the **exact upstream RomM 5.2.0** source
`backend/config/__init__.py`, `OIDC_ROLE_VIEWER` is a `str | None`
from `_get_env` — **not** a parsed comma-separated set.
`backend/handler/auth/base_handler.py` checks
`OIDC_ROLE_VIEWER in userinfo[OIDC_CLAIM_ROLES]` and, if no configured
single role matches, returns HTTP 403
`User has not been granted any roles for this application.`

The configured string `family,media` therefore asks for that **literal
group**, whereas Authentik users have the group `family`. This exactly
matches the observed 403 after successful OIDC token exchange.
**Important version caveat:** newer RomM branches changed roles to
comma-separated sets, so do not infer 5.2.0's semantics from `main` docs.

## Single-line change

Set `OIDC_ROLE_VIEWER=family` in the RomM Deployment. Keep
`OIDC_ROLE_ADMIN=authentik-admins`; do not use `*` and do not
modify Authentik mappings, enable previously disabled accounts, or
grant family admin rights. This intentionally does **not** grant a
media-only identity viewer access; inspect actual access requirements
before changing the group.

## Acceptance after GitOps merge

1. Argo `apps-games` observed/synced/healthy on exact merge SHA.
   Pod spec and runtime env reflect the new **one-group** value.
2. Browser Authentik login with the **active** e2e-user who belongs to
   family; confirm callback HTTP success and RomM `/api/users/me`
   responds with viewer role (not admin). Do not export the JWT.
3. Negative: test no-role identity/guest has no access; admin remains
   authorized under `authentik-admins`.
4. User-visible games library browsing (with permitted content), save
   progress/metadata persistently, and qualify CNPG/PVC backup and
   isolated restore separately; no ROM downloads without authorisation.

Rollback: revert only `OIDC_ROLE_VIEWER` to its previous value via PR.
Never revert to broad `*` unless a separate security decision is made.

Version-pinned upstream sources:
- https://github.com/rommapp/romm/blob/5.2.0/backend/config/__init__.py
- https://github.com/rommapp/romm/blob/5.2.0/backend/handler/auth/base_handler.py
- https://github.com/rommapp/romm/blob/5.2.0/env.template
