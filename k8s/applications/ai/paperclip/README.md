# Paperclip V1

Paperclip is the control plane for the software factory. The Kubernetes deployment intentionally reuses the homelab's existing platform primitives:

- Argo CD for desired-state delivery.
- Paperclip Operator `0.19.1`.
- CloudNativePG PostgreSQL on `longhorn-fast`.
- Barman/WAL + scheduled base backups to Hetzner Object Storage.
- ESO/Doppler for bootstrap/runtime secrets.
- LiteLLM as the single model gateway.
- Cilium + Gateway API + private ExternalDNS/UniFi for local-first access.
- Velero/Kopia for the Paperclip data PVC.

## Deployment contract

The Paperclip server deployment is operator-native, not a hand-built Deployment. The canonical workload is `paperclip.inc/v1alpha1 Instance/paperclip`; the operator owns the generated workload, Service, RBAC and lifecycle resources.

The installed operator API already exposes the first-party Kubernetes execution surface through:

- `spec.plugins`;
- `spec.adapters.execution`;
- per-tenant `ResourceQuota` / `LimitRange`;
- Cilium-aware sandbox egress policy.

Do not replace the operator with bespoke Deployment/Job plumbing.

Git desired state currently pins the Paperclip server image in `instance.yaml`. CLI/company tooling may be newer than the live server; do not infer a runtime upgrade from the CLI version. Server upgrades remain separately qualified because they can include database migrations and adapter/default changes.

## Required Doppler keys

In `cluster/prd`:

- `APP_PAPERCLIP_BETTER_AUTH_SECRET`
- `APP_PAPERCLIP_SECRETS_MASTER_KEY`
- `APP_PAPERCLIP_LITELLM_API_KEY`

The LiteLLM value must be a dedicated virtual key limited to the models needed by Paperclip. Do not use the LiteLLM master key.

## Authentication

Paperclip runs in `authenticated` mode at `https://paperclip.smadja.dev` and its HTTPRoute attaches only to `Gateway/internal`.

The automatic authenticated-mode `adminUser` bootstrap is intentionally not used. Claim the instance through the supported board-claim flow.

## Human admin bootstrap

The production instance runs in `authenticated` mode and must have a real Better Auth board user before browser-only flows such as the Paperclip Cloud Connector callback can succeed.

The initial account is bootstrapped by the upstream operator through `spec.auth.adminUser`:

- login: `paperclip-admin@smadja.dev`;
- password source: ExternalSecret `paperclip-admin-bootstrap`, key `password`;
- Doppler source key: `APP_PAPERCLIP_ADMIN_PASSWORD`;
- the bootstrap secret is deliberately separate from `paperclip-runtime-secrets`, so a missing bootstrap credential cannot disturb `BETTER_AUTH_SECRET` or LiteLLM runtime credentials;
- the upstream bootstrap Job is idempotent and promotes the account to the initial instance admin/CEO.

Do **not** set `spec.auth.disableSignUp: true` before the first bootstrap completes: the upstream bootstrap Job begins with the regular email sign-up endpoint. After `status.bootstrap` is `ready` and browser login is proven, close self-service sign-up in a separate hardening change.

The bootstrap password is a one-time human credential and must never be committed to Git.

## Managed GitHub connection

Paperclip `2026.916.1` already contains the upstream managed GitHub identity path; no server upgrade is required just to expose it.

On a self-hosted instance, the upstream `managed` GitHub method is intentionally hidden from the advertised gallery until the instance is enrolled with the Paperclip Cloud Connector and the broker advertises the `github.code` profile. Seeing only `mcp-key` before enrollment does **not** mean that a PAT is required.

The canonical V1 path is:

1. keep the advanced PAT method unused;
2. allow Paperclip server egress only to the production broker `my.paperclip.app:443` and the hosted GitHub MCP endpoint `api.githubcopilot.com:443` in addition to the existing GitHub API surfaces;
3. complete the upstream self-host enrollment as an instance administrator;
4. authorize the upstream GitHub App with selected repository access;
5. install that managed connection for the Implementation Engineer (or Company when explicitly intended);
6. prove clone/fetch, branch/push and PR creation in the separately approved DOC smoke.

Self-host enrollment generates the upstream signing/sealing identity in Paperclip's persistent instance data under its owner-only secrets directory. Do not copy that identity into Doppler or replace it with a custom Kubernetes Secret unless upstream changes its storage contract. Paperclip Cloud owns the fixed OAuth callback and webhook inbox; provider credentials are sealed to the enrolled instance and persisted in Paperclip's existing encrypted secret store.

Enrollment, GitHub authorization and managed-connection installation are credential/access mutations and remain explicit R2 gates. The harmless DOC smoke is a separate R2 gate.

## Execution posture

There are two distinct concerns:

1. **Paperclip server placement** — already Kubernetes-native through the Paperclip Operator.
2. **Agent execution placement** — currently bootstrap-local through `opencode_local`, with the first-party Kubernetes sandbox provider as the target production boundary.

`opencode_local` is acceptable for the first harmless DOC smoke because it proves Company -> issue DAG -> delegation -> review -> PR without changing the runtime boundary at the same time. It is not the final security boundary for autonomous production work.

The target is the upstream `@paperclipai/plugin-kubernetes` execution path backed by Kubernetes sandboxes, with role/capability restrictions enforced by pod, network, credential and RBAC boundaries rather than prompts alone.

A non-live candidate overlay and qualification runbook live under:

`poc/kubernetes-execution/`

That overlay is deliberately not referenced by the production `kustomization.yaml` and must not be enabled as part of an unrelated Paperclip change.

Qualification order:

1. complete Company/backlog bootstrap;
2. run the harmless DOC smoke with the existing local adapter;
3. run one disposable Kubernetes-sandbox POC with no production credential;
4. prove namespace/pod cleanup, egress restriction, resource quotas and callback/model path;
5. migrate roles progressively;
6. only then treat Kubernetes sandbox execution as the production factory runtime.

Known upstream sandbox/runtime-image defects must be treated as upstream blockers, not patched inside running Paperclip containers.

## Company and backlog

`company/` is the portable Company definition. Git remains canonical for Company intent.

`company/projects/kube-ops/backlog-seed.yaml` is the canonical backlog inventory. Paperclip does not natively import that seed format, so `scripts/paperclip/import-backlog-seed.mjs` is the bounded one-shot adapter from the Git seed to the official Paperclip issues API. It defaults to dry-run, uses stable managed-description markers for identity, and must not create or update live issues without a separately approved R2 apply.

Paperclip stores runtime work state; it does not replace Git as desired state.
