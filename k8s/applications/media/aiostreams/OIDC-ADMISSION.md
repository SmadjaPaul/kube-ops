# AIOStreams + Authentik OIDC — staged admission runbook

**STATUS: NOT ADMITTED.** All three *dormant* Kubernetes files in this
PR are **not** loaded by the active Kustomize roots. The existing Media
root remains unchanged. Merging this preparation PR does not enable OIDC.

## Verified contracts

- AIOStreams v2.37.0: OIDC authenticates dashboard and configuration
  page only. It does **not** authenticate Stremio addon URLs, TV devices
  or provision per-family profiles. Each addon URL remains a bearer secret.
- Strict callback: `https://aiostreams.smadja.dev/api/v1/auth/oidc/callback`.
- Authentik per-provider mode ordinarily publishes issuer
  `https://auth.smadja.dev/application/o/aiostreams/`. Never substitute
  the Authentik root URL without checking the exact `issuer` in the
  provider discovery document (the global-issuer mode differs).
- Existing Authentik mapping `oauth-scopes.yaml` emits
  `groups: [group.name, ...]`, including `authentik-admins`.
- Only Authentik admins receive `admin`; all other groups denied for
  the pilot. Do **not** grant `family=createConfig` until per-user
  secret/config isolation and authorisation are proven.
- `AIOSTREAMS_AUTH_REQUIRED=true`; retain a single recovery Basic user,
  via `APP_AIOSTREAMS_OPERATOR_AUTH`. Set `AIOSTREAMS_OIDC_LINK_BY_USERNAME=false`,
  `AIOSTREAMS_OIDC_USERNAME_CLAIM=sub`, and `USERNAME_PREFIX=sso:`.
  Never log or disclose the recovery account.
- The SSO flag currently remains **false** in the live Deployment.
- Current network policy allows only DNS. OIDC needs HTTPS to
  `auth.smadja.dev` through the **internal** Gateway or an equivalent
  issuer-valid path; qualify Cilium selectors/FQDN, DNS, TLS and the
  exact Service/Endpoint before admission. Do NOT add `world:443`.
  Test OIDC discovery, code exchange, userinfo and JWKS as relevant.
- The private AIOStreams route is `Gateway/internal` only. Keep it so.

## Two-sided secret wiring

The same existing Doppler **name**, not a plaintext value:

`APP_AIOSTREAMS_OIDC_CLIENT_SECRET` in `cluster/prd`

* Authentik: dormant `authentik-blueprint-aiostreams-oidc` ExternalSecret
  -> K8s Secret in `auth` with env key `AIOSTREAMS_CLIENT_SECRET`
  -> Authentik `global.envFrom` and optional worker reloader annotation.
* AIOStreams: dormant `aiostreams-oidc` ExternalSecret
  -> K8s Secret in `media` with env key
  `AIOSTREAMS_OIDC_CLIENT_SECRET` -> Deployment env.

Existing blueprint `extra/blueprints/apps-aiostreams.yaml` already
references `!Env AIOSTREAMS_CLIENT_SECRET` and has a strict callback.
It is currently **excluded** from the active ConfigMap generator.
Do not import it before its environment key is available to the
Authentik worker; a failed blueprint parse is not a successful provider.

## Prerequisites and sequence

1. Bootstrap AIOStreams runtime: BOTH
   `APP_AIOSTREAMS_SECRET_KEY` (32-byte hex) and
   `APP_AIOSTREAMS_OPERATOR_AUTH` (`username:strong-password`),
   ExternalSecret Ready, HTTP 200 and a tested local recovery login.
   The local provider remains operational during Authentik outage.
2. Qualify the exact Authentik issuer over HTTPS from the intended
   AIOStreams network path: check successful `.well-known`, matching
   JSON `issuer`, token endpoint, TLS and DNS. Never log tokens.
3. Provision `APP_AIOSTREAMS_OIDC_CLIENT_SECRET` once; do not replace
   existing values. Admit the TWO dormant ExternalSecrets in their
   respective Kustomizations; verify readiness without reading values.
4. Add `authentik-blueprint-aiostreams-oidc` to Authentik `global.envFrom`
   and worker reloader. Add `apps-aiostreams.yaml` to the active
   Authentik blueprint ConfigMap. Reconcile and inspect blueprint status.
5. Only after successful provider creation, add the dormant deployment
   patch and the reviewed minimal Cilium rule to an admission PR. Confirm
   patch actually overrides existing OIDC_ENABLED=false in the final
   Kustomize render (otherwise OIDC remains disabled).
6. Test one admin SSO login and negative tests: `family` without mapping,
   missing group claim, wrong callback, wrong issuer, invalid secret,
   disabled identity and username collision. Keep local fallback working.
7. Once user-config and provider-token isolation are proven,
   separately decide whether `family=createConfig` should be added.
   This is not the same as Stremio/TV login or account provisioning.
8. Keep zero-video-proxy/cloud-video E2E as a **separate** release gate.

## Source evidence

- https://docs.aiostreams.viren070.me/guides/sso/
- https://github.com/Viren070/AIOStreams/blob/v2.37.0/packages/docs/content/docs/configuration/environment-variables.mdx
- https://docs.goauthentik.io/add-secure-apps/providers/oauth2/
- https://github.com/SmadjaPaul/kube-ops/blob/main/k8s/infrastructure/auth/authentik/extra/blueprints/oauth-scopes.yaml
