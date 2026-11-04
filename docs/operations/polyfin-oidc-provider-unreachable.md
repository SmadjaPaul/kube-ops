# Polyfin 0.60 OIDC provider_unreachable — internal Gateway diagnosis

Operator report 2026-11-04: Nebula installation PASS; the OIDC start
redirects to provider_unreachable; user OIDC and music playback not executed.

## Verified upstream behavior

- In moodiness/polyfin v0.60.0 internal/admin/provider.go, providerStart
  calls oidc.Client.AuthorizationURL; all discovery failures become
  provider_unreachable, before callback or user-account checks.
- In internal/oidc/oidc.go, discovery performs GET of
  https://auth.smadja.dev/application/o/polyfin/.well-known/openid-configuration
  and requires the JSON issuer to equal the configured value *exactly*,
  including a trailing slash. Network, TLS, HTTP status, JSON and issuer
  mismatch can produce the same user-facing error.
- The Authentik HTTPRoute attaches to both internal and external Gateways.
  The internal HTTPS wildcard Gateway and Polyfin egress already permit
  10.0.20.192:443. Polyfin historically pins aiostreams.smadja.dev to
  this IP in its Pod hostAliases, but not auth.smadja.dev.

## Narrow mitigation

The active parent media Kustomization appends auth.smadja.dev to the
existing Polyfin Pod hostAliases, resolving both names to the internal
Gateway VIP 10.0.20.192. This preserves SNI and TLS verification, changes
no global DNS, AIOStreams, Authentik or Cilium egress policy, and makes no
new public route. The historic pilot source and gate remain untouched.

This is a plausible mitigation, NOT proven root cause. If the Pod's
resolver already returned the VIP, the patch does not change its route.

## Runtime evidence after Argo reconciliation

1. Check live Deployment/Pod revision, the two entries in /etc/hosts,
   DNS A/AAAA answers from Pod/CoreDNS/UniFi, and the internal Gateway
   HTTPRoute status Accepted/ResolvedRefs.
2. In the Polyfin network namespace, using a non-persistent diagnostic
   tool only if the runtime image lacks curl, compare normal HTTPS
   discovery with forced private VIP:
   curl --resolve auth.smadja.dev:443:10.0.20.192
   https://auth.smadja.dev/application/o/polyfin/.well-known/openid-configuration
   Keep TLS verification enabled (never -k). Sanitize output to status,
   selected IP, TLS verdict, time and JSON issuer; never log secrets.
3. Confirm exact JSON issuer versus Polyfin providerIssuer; note the
   final slash. Inspect endpoints for authorization, token and JWKS.
4. Inspect the specific Polyfin log warning
   "The identity provider could not be reached"; categorize its error.
   Do not export full logs, headers, cookies or authorisation codes.
5. Check Hubble for Polyfin-to-VIP flows and Gateway-to-Authentik. If
   502/404, inspect Gateway/backend status; if TLS error, inspect
   certificate chain/SNI; if issuer mismatch, correct the exact field
   through authorized native Polyfin API rather than database SQL.
6. Prove browser OIDC login as an existing family non-admin (e2e-user),
   verify isAdministrator=false, then continue music search/TorBox
   warm/cold cache and Web Player tests. Do not use breakglass as
   evidence for family login.

## Rollback

If the private VIP path is healthy but provider_unreachable persists,
do not open blanket Internet egress. Investigate discovery's concrete
failure first. Revert this single parent Kustomization patch if needed;
AIOStreams continues using its original entry.

References:
https://github.com/moodiness/polyfin/blob/v0.60.0/internal/admin/provider.go
https://github.com/moodiness/polyfin/blob/v0.60.0/internal/oidc/oidc.go
https://github.com/SmadjaPaul/kube-ops/blob/main/k8s/infrastructure/auth/authentik/httproute.yaml
