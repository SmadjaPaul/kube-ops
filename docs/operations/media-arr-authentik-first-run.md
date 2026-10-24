# PLT-118 — Arr SSO without an initial local administrator

Status: Phase A proposal, separate Phase B dormant manifest in Git.
**Do not enable External auth until every Phase A runtime gate passes.**

## Confirmed upstream approach

Radarr 6 / Sonarr 4 / Prowlarr accept AuthenticationMethod=External in
config.xml or the APP__AUTH__METHOD=External environment setting. The
initial local-admin form is therefore unnecessary, but External bypasses
application login entirely. Authentication is enforced by Authentik's
Proxy Provider and its managed Proxy Outpost.

Official references:
- https://github.com/Servarr/Wiki/blob/master/radarr/faq.md
- https://github.com/Servarr/Wiki/blob/master/radarr/settings.md
- https://integrations.goauthentik.io/media/sonarr/
- https://docs.goauthentik.io/add-secure-apps/providers/proxy/create-proxy-provider/
- https://docs.goauthentik.io/add-secure-apps/outposts/integrations/kubernetes/
- https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/

## Phase A (this PR): route and policy without disabling app login

- Three Authentik proxy-mode providers, not fake OAuth2 callbacks.
- Reuse existing Proxy Outpost (including Frigate provider).
- Restrict Arr app authorization to authentik-admins and explicitly retire
  the old Media Users policy bindings (policy engine mode is `any`).
- Three LAN HTTPRoutes forward exclusively to auth/ak-outpost-proxy-outpost:9000.
- Add named auth namespace ReferenceGrant for the media HTTPRoutes.
- Remove direct host/Gateway ingress grants for TCP 7878/8989/9696.
- Permit the managed proxy outpost to reach these three app listeners.
- Internal media pods retain authorized API-key Service access.
- App auth remains as it was: the first-run form MAY remain until Phase B.

Do not merge this PR until Authentik blueprint composition has been reviewed:
the outposts blueprint now uses the upstream `metaapplyblueprint` model to
apply `Apps - Media` first. Runtime must still verify its required target
resolves and the outpost refreshes successfully.
The prior OAuth2 provider objects are intentionally retained for now to avoid
destructive cleanup; inspect drift and references after deployment.

## Required runtime proof before Phase B

1. Validate managed outpost Service, Pod labels and EndpointSlices, Frigate
   SSO regression, Authentik blueprint statuses, and group authorization.
2. Check Gateway HTTPRoute Accepted/ResolvedRefs and TLS/DNS.
3. Anonymous browser to each hostname must redirect to Authentik;
   account in authentik-admins must enter; unprivileged media user must be denied.
4. Prove there is **no direct bypass** using Pod IP, ClusterIP from untrusted
   namespaces, host network and either Gateway, and review all other Cilium
   and clusterwide policies (additive allows can override intended isolation).
5. Confirm API clients Seerr, Prowlarr, Configarr can still reach in-cluster
   Services via API keys; never send those clients through Authentik browser URLs.
6. Test fresh browser/logout, unauthorized /initialize.json and /api/v3 paths.

## Phase B: switch immediately to the final login model

Only after Phase A passes, copy and adapt the dormant optional
k8s/optional/arr-external-auth/env-patch.yaml into the active Arr Kustomization
in a **separate PR** and enable APP__AUTH__METHOD=External per application.
No local app account needs to be created, either before or after this step.
Test each application's first-run form is gone; Authentik SSO remains enforced,
and all existing config PVCs remain intact. Rollback: remove External env
while retaining the proxy barrier; never remove the proxy before restoring
application-level authentication.

## Cautions

- Do not conflate Authentik login with native Arr OIDC; it is reverse-proxy SSO.
- No unauthenticated /api* path exemptions; API clients use internal Services.
- Do not disable authentication for LAN or trust forged X-Forwarded-For.
- Avoid runtime manual auth edits or synthetic accounts.
- The disabled phase-B patch is only a reviewed template; it is NOT active.
- Do not claim RECONCILED/RUNTIME/USER on a CI-only pass.
