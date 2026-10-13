# Mastra Factory — deployed, not yet qualified for autonomous use

The previous 'STAGED, NOT ENABLED' instructions became obsolete when Factory
was deployed. The current parent `k8s/applications/platform/kustomization.yaml`
**already includes** `mastra-factory` at one replica. Do **not** repeat the
old activation, remove the deployment or deploy a second Factory.

Latest verified rollout (2026-10-14):
- `factory-platform@87efe11670758f7e6acdfa48819d058fd5390018`
- `kube-ops@a532a023cb31eb602c350b7023e3ad7a245daa25`
- `ghcr.io/smadjapaul/mastra-factory@sha256:f328cb9688ed1a5b3d5113b42413b946504afff7b9db426a3a824650b199658e`
- Argo Synced/Healthy; Pod Ready; HTTP `/health` 200; CNPG 1/1 healthy.

Those are **deployment** checks, not Factory Issue→PR E2E proof.

## Pending operator/security gates

1. Better Auth is enabled; Authentik human SSO, authorized session and
   cross-user denial remain unproven. **Do not grant Personal Agent access.**
   Verify current Better Auth/Factory login compatibility and Mastra Studio's
   published production SSO licensing boundary before proceeding.
2. Factory model settings report no configured provider. The standalone
   `agentgateway` namespace exposes a private, budget-limited endpoint on
   port 4000 with `factory/fast` and `factory/code`. Configure the custom
   provider/default **inside an authenticated Factory session**; the model
   registry is not populated by Kubernetes env automatically.
3. A dedicated GitHub App must be created, installed only on authorized repos,
   and supplied through secrets. The signed webhook is
   `https://factory.smadja.dev/web/github/webhook`. It requires six variables:
   `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_CLIENT_ID`,
   `GITHUB_APP_CLIENT_SECRET`, `GITHUB_APP_SLUG`, `GITHUB_APP_WEBHOOK_SECRET`.
   Do not ship a partial group or expose secrets in Git.
4. Upstream Factory documents that GitHub App installation tokens can fail
   for `gh` inside sandboxes. **Do not give agents a persistent classic PAT.**
   Verify scoped installation tokens with Git HTTPS/REST or a narrow, audited
   mediated transport, then prove a real clone, push and PR.
5. Kubernetes gVisor is available, but Factory-native SandboxClaim, replay
   and cleanup remain untested. Keep the sandbox Cilium default-deny policy.
6. Native Factory LLM call, Tempo trace, immutable harness lock at authenticated
   dispatch and Meta Loop Board approval are still runtime gates.
7. Keep Paperclip until a real Factory Issue→PR E2E passes.

## Authentik blueprint

`k8s/infrastructure/auth/authentik/extra/blueprints/apps-mastra-factory.yaml`
is committed as a **dormant template**, not part of the generated blueprint
ConfigMap. It depends on a separate Doppler-provided
`MASTRA_FACTORY_OIDC_CLIENT_SECRET` and a verified Better Auth OAuth callback
route. Do not load it before those prerequisites and the production SSO license
question are resolved. Do not create an ExternalSecret pointing at a missing
Doppler key, since that would degrade the active Authentik reconciliation.

## Deployment / rollback

Keep all image changes pinned to an immutable GHCR digest, through a targeted
`kube-ops` PR and Argo CD. Never `kubectl apply` an ad hoc substitute.
Avoid destructive CNPG/PVC changes and cleanup of restore-drill data without
explicit validation. CI unavailable for billing is not a successful test.

Implementation and onboarding runbook:
`SmadjaPaul/factory-platform/mastra-factory/docs/operator-activation-gates.md`.
Official references: https://factory.mastra.ai/configure/auth ,
https://factory.mastra.ai/configure/models ,
https://factory.mastra.ai/configure/github .
