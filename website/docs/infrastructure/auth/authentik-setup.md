---
sidebar_position: 1
title: Authentik Setup Guide
description: Canonical Authentik identity and OIDC contract for the homelab
---

# Authentik SSO Integration Guide

Authentik is the cluster identity provider. The V1 target is Authentik 2026.8.3,
managed through Git-backed Blueprints and exposed only through Gateway API at
`https://auth.smadja.dev`.

## Architecture

```text
Browser
  -> Cloudflare
  -> Cloudflare Tunnel
  -> Cilium Gateway API
  -> authentik-server ClusterIP
  -> Authentik
```

The server Service is intentionally `ClusterIP`; Gateway API is the only
application entrypoint.

Native OIDC is preferred for applications that support it. A managed Authentik
Proxy Outpost is retained only for applications that cannot consume OIDC
directly (currently Frigate). Authentik-managed Ingress and HTTPRoute creation
is disabled so application exposure remains Git-owned.

## Authentication flow

V1 reuses Authentik's packaged `default-authentication-flow` and applies only
small, explicit overlays:

- email or username identification;
- account-enumeration protection with `pretend_user_exists`;
- no matched-user disclosure before authentication;
- native WebAuthn/passkey conditional UI through the default authenticator
  validation stage;
- WebAuthn user verification required when a device is used;
- browser-close login sessions with no remember-device persistence.

The old reference-repository `passwordless-authentication-flow` and its
parallel WebAuthn setup flow are deliberately removed. Authentik's upstream
flow remains the authority.

## Brand and login presentation

The canonical Brand is `authentik-default`, which ensures pre-authentication
flows resolve consistently for `auth.smadja.dev`.

The default flow background uses Authentik's bundled asset:

```text
/static/dist/assets/images/flow_background.jpg
```

Logo and favicon also use bundled Authentik assets. This avoids an external
branding dependency on another domain.

## Reverse proxy contract

Authentik 2026.8 trusts forwarded headers only from configured proxy networks.
The deployment therefore sets `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` and
`AUTHENTIK_WEB__BASE_URL=https://auth.smadja.dev`.

If login pages show mixed-content failures or an endless loading state, first
verify the direct Gateway-to-Authentik peer address and forwarded
`Host`/`X-Forwarded-Proto` headers before changing the trust list.

## Privacy and lifecycle

Git/Renovate own Authentik upgrades. The deployment disables Authentik startup
analytics and the built-in update checker, and keeps error reporting disabled.

Database state is stored in CloudNativePG. Backups are sent to the canonical
Hetzner Object Storage path and are part of the separate backup/restore
contract.

## Authorization

Applications should have explicit group or policy bindings. Authentication
success alone is not an authorization decision.

The canonical platform groups include:

- `authentik-admins`: Authentik superuser administration;
- `admin`: platform administration without implicitly making the user an
  Authentik superuser;
- `family`, `dev`, `media`, `data`, `iot`: workload-facing access
  groups.

Application-specific compatibility groups remain only where an application
blueprint still consumes them.

## Runtime acceptance

Authentik is not considered V1-ready from pod health alone. Acceptance requires:

1. a fresh private-browser login using a normal human password;
2. completion of the post-login redirect with no infinite loading state;
3. Argo CD OIDC through Dex and Authentik;
4. OpenWebUI login and usable main UI;
5. Home Assistant onboarding/login and the expected MQTT/Zigbee2MQTT path;
6. authorization matching the user's groups.

Recovery links are break-glass mechanisms and do not count as a normal human
login test.

## Troubleshooting

For an authentication failure, collect the smallest useful evidence:

- the last `/api/v3/flows/executor/default-authentication-flow/` response;
- whether the authenticated session cookie was created;
- whether the browser requested the final `next` URL;
- the active Brand from `/api/v3/core/brands/current/`;
- server/worker BlueprintInstance errors;
- proxy scheme/host observations.

Never print passwords, cookies, tokens, OIDC client secrets, or recovery links.
