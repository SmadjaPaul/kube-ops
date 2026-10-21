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

1. Better Auth is the chosen Factory identity provider: email/password,
   no Authentik OIDC for Factory. Create the initial operator using the
   short-lived, token- and email-scoped bootstrap described in
   `factory-platform/mastra-factory/docs/better-auth-operator.md`.
   Disable bootstrap afterward. Validate sign-in, session persistence,
   unauthorized API access and isolation. **Do not grant Personal Agent access**
   until the security E2E is proven.
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

## Identity ownership

Factory owns its own Better Auth login and sessions, backed by its existing
CNPG storage. Authentik remains the identity provider for other applications
but does **not** own Factory accounts. The previously staged Factory-specific
OIDC blueprint has been removed because it was dormant and not selected.
No active Authentik blueprint or secret is modified.

## Deployment / rollback

Keep all image changes pinned to an immutable GHCR digest, through a targeted
`kube-ops` PR and Argo CD. Never `kubectl apply` an ad hoc substitute.
Avoid destructive CNPG/PVC changes and cleanup of restore-drill data without
explicit validation. CI unavailable for billing is not a successful test.

The O3 delivery path is deliberately one-way and digest-bound:

1. ARC CI qualifies the exact Factory source SHA.
2. Cloud Build publishes `candidate-<source-sha>`, records OCI/SBOM evidence,
   and promotes only the matching immutable `sha-<source-sha>` tag.
3. A GitOps PR updates only this Deployment with
   `scripts/promote-mastra-factory-digest.sh <source-sha> <digest>`.
4. Argo CD reconciles the merged kube-ops revision.

Until those external observations exist, `GITOPS_PR`, `ARGO_REVISION`,
`SMOKE` and `ROLLBACK` are **UNKNOWN**. A local manifest edit or a successful
static check is not runtime evidence.

Implementation and onboarding runbook:
`SmadjaPaul/factory-platform/mastra-factory/docs/operator-activation-gates.md`.
Official references: https://factory.mastra.ai/configure/auth ,
https://factory.mastra.ai/configure/models ,
https://factory.mastra.ai/configure/github .

## Authentik OIDC — dormant until Doppler credentials exist

Implementation: `factory-platform/mastra-factory/docs/authentik-oidc.md`.
The OIDC provider and optional env hook are versioned, but **no credential
was fabricated or activated during this PR**. Existing Better Auth sessions
remain valid, and absent OIDC credentials leave the default login unchanged.

Activation sequence:

1. Create distinct `APP_MASTRA_FACTORY_AUTHENTIK_OIDC_CLIENT_ID`
   (value `mastra-factory`) and `APP_MASTRA_FACTORY_AUTHENTIK_OIDC_CLIENT_SECRET`
   in Doppler, keeping both stable across namespaces.
2. Add `oidc-external-secret.dormant.yaml` to THIS kustomization's resources.
   Wait for ExternalSecret `mastra-factory-authentik-oidc` to become Ready.
3. Add `factory-oidc-external-secret.dormant.yaml` to
   `k8s/infrastructure/auth/authentik/extra/kustomization.yml`, add the
   matching `authentik-blueprint-factory-oidc` envFrom secret to the Authentik
   worker/server values, and add `blueprints/apps-factory.yaml` to the active
   ConfigMap generator. Verify Authentik blueprint successfully reconciles.
4. Verify Authentik discovery at
   `https://auth.smadja.dev/application/o/factory/.well-known/openid-configuration`,
   and strict callback
   `https://factory.smadja.dev/auth/api/callback/authentik`.
5. Promote a new Mastra Factory digest containing Generic OAuth before
   interpreting `/auth/api/oidc/login` as a supported login flow.
6. Prove allowed Authentik `admin` login, denied `dev` login, session
   continuity and correct organization and Factory settings access. Keep
   operator bootstrap fallback until recovery is validated.

Do not add the dormant ExternalSecrets before their remoteRef Doppler keys
exist: missing keys can degrade the Authentik rollout. Existing Factory
workload references the OIDC Secret as optional for this reason.

## Durable sandbox checkpoint S3 — dormant until isolated storage exists

Factory `origin/main` contains the PLT-109/PLT-24 checkpoint implementation.
It is deliberately disabled when no complete S3 configuration is present. The
Deployment references `mastra-factory-checkpoint-s3` through an optional
`envFrom`; the ExternalSecret is kept out of the active Kustomization until
its prerequisites are complete.

The required contract is:

| Doppler key | Factory variable | Policy |
| --- | --- | --- |
| `FACTORY_CHECKPOINT_S3_ENDPOINT` | `FACTORY_CHECKPOINT_S3_ENDPOINT` | HTTPS endpoint only |
| `FACTORY_CHECKPOINT_S3_REGION` | `FACTORY_CHECKPOINT_S3_REGION` | `fsn1` |
| `FACTORY_CHECKPOINT_S3_BUCKET` | `FACTORY_CHECKPOINT_S3_BUCKET` | `smadja-dev-factory-checkpoints` |
| `FACTORY_CHECKPOINT_S3_PREFIX` | `FACTORY_CHECKPOINT_S3_PREFIX` | `factory-checkpoints/v1` |
| `FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID` | `FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID` | dedicated key |
| `FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY` | `FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY` | dedicated key |
| `FACTORY_CHECKPOINT_INTERVAL_SECONDS` | `FACTORY_CHECKPOINT_INTERVAL_SECONDS` | at most `300` |

The checked-in dormant manifest is
`checkpoint-s3-externalsecret.dormant.yaml`. It must not reuse
`cnpg-hetzner-credentials` or the shared `HETZNER_S3_*` identity. The
existing bucket `smadja-dev-homelab-backups` is shared by CNPG, Velero and
Longhorn; it is not an acceptable Factory identity without a reviewed
bucket-policy/key isolation proof. `homelab-infra` must provision the private
Factory bucket/policy (`smadja-dev-factory-checkpoints`) and place the values
in Doppler `infrastructure/prd`.

The qualification fixture and controlled claim-loss exercise are recorded in
`docs/operations/plt-109-plt-24-checkpoint-s3-qualification-2026-10-21.md`.
They remain `NOT_EXECUTED`; RPO and RTO remain `UNKNOWN` until a real private
S3 upload/download and a disposable `SandboxClaim` disappearance drill have
been approved and observed. Destructive checkpoint GC remains inactive until
live-reference protection is proven.
