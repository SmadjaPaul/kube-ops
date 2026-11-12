# Hermes Personal Agents — PLT-158 (staged, zero tenants)

**Active only as an empty foundation**: platform root imports the Hermès
AppProject and ApplicationSet, but the registry has zero tenants, so no user
agent, HTTPRoute, credential, or PVC is deployed.

This is an **unofficial community Helm chart** at fixed Git commit
`e3b685d4d0288668a37216435742cd0a659ebc6c` in **direct deployment mode**.
It is not an operator. Each generated Argo Application has one Helm release,
one namespace, one single-writer Longhorn PVC, and a separate Doppler ESO
reference. Official Hermes `v0.23.0` image is pinned to the observed Docker Hub
multiarch index digest `sha256:adb7890916de63245523492be8f68f9d2095fecbec4e2a6dab7960381f0fc002`;
verify this digest directly with the registry and platform admission before use.

## Vision and onboarding

An end user signs in via **Authentik** and only sees their own Hermes Dashboard/Chat.
A provider/application per user must bind **only that identity** (and explicit
breakglass admins) to the corresponding issuer and PKCE client; a generic
"family" OIDC binding is NOT sufficient. The Hermes dashboard and Webapp both
give their authenticated account access to the entire **instance**.

We must not treat Hermes profiles as tenant boundaries. All per-user tokens,
Google OAuth, MCP, memory, sessions, scheduled jobs, and workspaces stay in
their tenant namespace/PVC. The agent has no Factory, GitHub admin, Docker
socket or Kubernetes API access.

The current pilot admission tool is administrator-controlled:

```sh
python3 k8s/optional/hermes-personal/manage_tenants.py validate
python3 k8s/optional/hermes-personal/manage_tenants.py enroll t-a1234
python3 -m unittest discover -s k8s/optional/hermes-personal -p 'test_*.py'
```

It stores **opaque tenant identifiers only**, never names, e-mails, subjects,
credentials or medical data. It re-renders an ApplicationSet as JSON (valid
YAML). The present registry is **empty**. The final PLT-159 flow must automate
approved Authentik onboarding and a reviewed GitOps admission, without manual
YAML authoring for new family members.

## Required gates before the FIRST tenant

1. Confirm actual chart and official OCI image digests, image architecture and
   runtime compatibility (the chart's published default tag 0.8.0 is stale).
2. Enroll two **consenting** pilot identities with OIDC PKCE issuer/client
   created in Authentik, explicitly restricted one-to-one.
3. Provision a distinct Doppler key `APP_HERMES_T_XXXX_LLM_KEY` per tenant,
   and prove ESO Ready. Do not reuse Factory credentials.
4. Verify the exact Agentgateway OpenAI-compatible API path/model `factory/fast`
   and per-tenant identities, quotas and no prompt logging of health data.
5. Confirm Cilium labels/ports (9119), auth.smadja.dev egress, probes, init/migrations,
   Webapp login/callback (including browser websockets), image pull and resources.
6. The empty foundation is already active from the platform root; verify Argo
   actually reconciled it, with healthy AppProject/ApplicationSet. No HTTPRoute
   exists yet: test the first tenant via scoped admin port-forward.
7. Only after negative A→B security tests, create **separate** authenticated
   HTTPRoutes to each user's Webapp. No shared management dashboard.
8. Restore one test PVC. Measure 2 and 5 active agents and estimate 20–30
   tenant capacity on the single 64GiB node; do NOT deploy 30 on assumptions.

## Safe pilot settings

- Cilium denies cross-tenant egress; only DNS, Agentgateway:4000 and
  Authentik HTTPS are enabled for the initial synthetic pilot.
- No direct external Google, Matrix or wellness egress until PLT-160 with
  individual scoped credentials and separate audited allowances.
- Local terminal/code execution/browser toolsets are disabled for the initial
  pilot. Introduce a separate sandbox before granting autonomous code execution.
- No backup/cleanup is automatically destructive; verify application data,
  Longhorn policies, retention, restore and offboarding before expansion.
- No public HTTPRoute. Namespace names derive from opaque IDs; Authentik apps
  enforce identity bindings. A guessed URL is never an access control.

Companion tickets: PLT-159 (provisioning/auth), PLT-160 (connectors), PLT-161
(Factory handoff), PLT-162 (runtime E2E + old coach cleanup).

## Runtime correction: dashboard is not the messaging gateway

The pinned community chart defaults to `args: [gateway, run]` while the
official Hermes v0.23.0 browser UI is launched via:
`hermes dashboard --host 0.0.0.0 --port 9119 --no-open`.

The tenant Helm values override `args` explicitly, expose Service port
**9119**, and set `dashboard.public_url` for OAuth callbacks. The previously
configured `webapp.enabled / webapp.port: 9120` was not the documented v0.23.0
dashboard entrypoint. The startup/readiness probes call `/api/status`; this
is a public readiness endpoint **not** a login/auth check. OIDC/WebSocket
security must be proven separately.

The dashboard process **does not replace** the long-running messaging gateway
(`hermes gateway run`). Add a separate, carefully qualified gateway process
or sidecar once Matrix/cron integration is actually needed. Check single-writer
SQLite/HERMES_HOME concurrency and backup safety before enabling it.

If an Authentik OIDC client is confidential, inject
`HERMES_DASHBOARD_OIDC_CLIENT_SECRET` into the tenant ESO Secret; for public
PKCE-only clients it is not necessary. The client's authorization binding must
restrict **only** the intended identity to this tenant. No browser route should
be published before this is verified.

Upstream v0.23.0 reference:
https://github.com/NousResearch/hermes-agent/blob/v0.23.0/website/docs/user-guide/features/web-dashboard.md
