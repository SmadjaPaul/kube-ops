# Mastra Factory — GitOps rollout gate

Status: **STAGED, NOT ENABLED**. The parent `k8s/applications/platform/kustomization.yaml` does not include this directory. Do not add it until all below are met.

Target: the official OSS Mastra Factory server packaged from `SmadjaPaul/factory-platform/mastra-factory`, no Mastra Platform subscription. Keep original Factory Intelligence service independent.

## Required before activation

1. CI-tested, GHCR-published `ghcr.io/smadjapaul/mastra-factory:sha-<verified commit>`. Replace the `UNPUBLISHED-REPLACE-ME` tag with its verified digest.
2. App-owned immutable secrets: Better Auth secret, Factory credential encryption (stable, backed up), OAuth state signing, scoped GitHub App (ID/PEM/client ID/client secret/slug/webhook secret). **The old telemetry collector App cannot be assumed suitable for login/webhooks.** Existing `factory-platform-ghcr` token may be used only for read:packages.
3. CNPG pgvector extension verified in the actual operand image; active WAL/archive backups; one restore check.
4. **Authentik OIDC sign-in proven inside Factory UI and API**; the upstream Better Auth bootstrap is not sufficient as a multi-user authentication integration. No exposure before this is proven.
5. Isolated sandbox provider verified; Factory's upstream `LocalSandbox` runs shell commands in the API pod and must not be used for untrusted code. Prefer upstream remote/VM adapter; no host Docker socket/Kube-admin secret.
6. GitHub App callbacks, install permissions, issue intake, code checkout, PRs and CI re-entry verified without a broad personal PAT. If GitHub webhooks need a public endpoint, grant only the exact signed webhook route, not the entire UI; private-only endpoint will not receive GitHub events.
7. Existing LiteLLM virtual key configured as custom model provider, `factory/code`, `factory/fast`; record actual spend without duplicate counting.
8. Authentik on user roles is not authorization for execution tokens. Separate worker identities.
9. Capacity check, readiness/probe checks and no live collision with Paperclip. Paperclip remains unchanged.

## Reconciliation

Do not `kubectl apply` manually or patch the live cluster. After all gates, review the manifests, commit the image digest, add `- mastra-factory` to the platform parent kustomization and reconcile through Argo CD. First keep `replicas: 0` until image/secrets/database are verified, then change to 1 after an explicitly reviewed promotion.

Configuration uses the internal Gateway only (`https://factory.smadja.dev`) and no external route or unauthenticated access. GitHub OAuth callback = `https://factory.smadja.dev/auth/github/callback`, Better Auth callback paths remain provider-specific.

## Optional integrations

Linear offers project hierarchy, prioritization, triage and business-facing planning, but duplicates GitHub Issues and adds a SaaS OAuth dependency. Do not enable without operator decision. Jira/Slack/GitLab/incident.io are already supported by the upstream template but not necessary now.
