# Agentic platform V1 — runtime acceptance runbook

This runbook is evidence-driven and current-state oriented. Durable changes go
through Git -> Argo CD -> Kubernetes. Runtime state is evidence, not desired state.

## Guardrails

- Refresh `main`, the active PR head and live Argo state before acting.
- Do not bypass TLS.
- Do not print secret values.
- Do not repair Kubernetes imperatively.
- Preserve the local-first baseline.
- R2 remains explicit and transaction-scoped.
- Do not combine Paperclip backlog import, first DOC smoke and Kubernetes
  sandbox migration in one change.

## Phase 0 — preflight

Record:

```
TEST_HEAD_SHA=
ARGO_BASELINE=
NODE_READY=
LOCAL_FIRST_BASELINE=
PAPERCLIP_INSTANCE_VERSION=
PAPERCLIP_OPERATOR_VERSION=
```

Verify required Paperclip ExternalSecrets are Ready without reading values.

## Phase 1 — static/render validation

- run repository validation;
- render the production Paperclip Kustomization;
- verify the `Instance` is present;
- verify no plaintext application credential was introduced;
- verify no unintended public route;
- if testing the non-live sandbox candidate, render
  `poc/kubernetes-execution` independently and prove it is not referenced by
  the production Kustomization.

Record:

```
STATIC_VALIDATION=
PAPERCLIP_RENDER=
SANDBOX_CANDIDATE_RENDER=
SECRET_SCAN=
PUBLIC_EXPOSURE_CHECK=
```

## Phase 2 — Paperclip control plane

Verify:

- Paperclip Operator Healthy/Synced;
- `Instance/paperclip` Ready;
- Service endpoints healthy;
- HTTPRoute Accepted/Programmed on `Gateway/internal`;
- private DNS resolves to the internal VIP;
- normal TLS succeeds;
- authenticated UI/API works.

Record:

```
PAPERCLIP_OPERATOR=
PAPERCLIP_INSTANCE=
PAPERCLIP_ROUTE=
PAPERCLIP_PRIVATE_DNS=
PAPERCLIP_TLS=
```

## Phase 3 — persistence and backup

Verify ESO, CNPG, WAL/base backup coverage and Paperclip PVC backup coverage.
Do not treat backup existence as restore proof.

Record:

```
PAPERCLIP_ESO=
PAPERCLIP_CNPG=
PAPERCLIP_WAL=
PAPERCLIP_BASE_BACKUP=
PAPERCLIP_PVC_BACKUP=
```

## Phase 4 — model path

Perform one minimal model request and prove:

```
Paperclip/OpenCode -> litellm.litellm.svc -> logical factory model
```

No workload may require the LiteLLM master key.

Record:

```
PAPERCLIP_LITELLM=
LOGICAL_MODEL=
MASTER_KEY_CONSUMER_PRESENT=
```

## Phase 5 — Company and backlog bootstrap

Company import is a distinct operation from backlog import.

For Company:

- exactly 1 Company;
- 5 agents;
- 2 projects;
- 7 skills;
- all `CAN_APPROVE_R2=false`;
- heartbeats disabled;
- workspaces `git_worktree`, baseRef `main`, branchTemplate
  `{{issue.identifier}}-{{slug}}`.

For SMA-31, the workspace lifecycle is qualified only when the evidence is
observed in the same run, in this order:

1. Paperclip creates or attaches the execution workspace before model
   invocation.
2. `currentExecutionWorkspace` is non-null and reports
   `mode=isolated_workspace` with `workspaceStrategy.type=git_worktree`.
3. The agent cwd is the resolved task worktree, not the project primary
   checkout, and `git branch --show-current` is the task-specific branch
   derived from `{{issue.identifier}}-{{slug}}`.
4. The resolved worktree is based on `main`.

Missing or inferred fields are `NOT_OBSERVED`, never `PASS`. The qualification
must not read Secret values or mutate Kubernetes or the Paperclip database.

For backlog:

- use `scripts/paperclip/import-backlog-seed.mjs`;
- dry-run first;
- stop on conflict or ambiguous identity;
- live apply requires a separate bounded R2;
- no assignment or agent execution as an import side effect.

Record:

```
COMPANY_READY=
BACKLOG_DRY_RUN=
BACKLOG_CREATE=
BACKLOG_UPDATE=
BACKLOG_CONFLICT=
BACKLOG_APPLIED=
AGENTS_STARTED_BY_IMPORT=no
```

## Phase 6 — first DOC smoke

Use the existing `opencode_local` path for this first smoke. The purpose is to
prove orchestration before changing execution infrastructure.

Create one harmless documentation-only task. The Manager must create a
dependency-aware graph with at least two children and route work through
Researcher -> Implementation -> Reviewer -> QA. Open a PR and do not merge it.

Record:

```
DAG_CREATED=
DELEGATION=
INDEPENDENT_REVIEW=
QA=
TEST_PR_URL=
SELF_MERGE=no
```

## Phase 7 — Kubernetes sandbox POC

Only after Phase 6 passes, qualify the first-party Kubernetes execution path.
Use the non-live candidate under `poc/kubernetes-execution` as the starting
point; refresh all upstream versions before activation.

The first POC must use one disposable agent/run and no production credential.

Prove:

- upstream `@paperclipai/plugin-kubernetes` is installed;
- sandbox backend starts successfully;
- per-run/per-tenant workload isolation exists;
- quota and limit range are present;
- Cilium egress policy matches the intended allow list;
- Paperclip callback and LiteLLM path work if explicitly enabled for the POC;
- unrelated private/internet egress is denied;
- sandbox has no Kubernetes write authority;
- no secret values are logged;
- cleanup is deterministic;
- existing Paperclip control plane remains healthy.

Do not patch plugin files inside a running container. If a published runtime
image/plugin defect blocks the POC, capture it as an upstream blocker.

Record:

```
K8S_SANDBOX_PLUGIN=
K8S_SANDBOX_BACKEND=
K8S_SANDBOX_ISOLATION=
K8S_SANDBOX_QUOTA=
K8S_SANDBOX_EGRESS=
K8S_SANDBOX_K8S_WRITE_DENIED=
K8S_SANDBOX_CLEANUP=
K8S_SANDBOX_UPSTREAM_BLOCKER=
```

## Phase 8 — role migration

Migrate roles only after the POC passes. Do not move all five agents at once.

Suggested order:

1. Researcher;
2. Reviewer;
3. QA & Release;
4. Implementation Engineer;
5. Engineering Manager.

For every role, prove its actual credentials, network access and Kubernetes
permissions match `company/CAPABILITIES.md`.

## Final regression

Re-run private DNS/TLS/Gateway checks for Authentik, OpenWebUI, Home Assistant
and Paperclip. Verify no unintended public route.

A failure is fixed with the smallest causal Git change, followed by Argo
reconciliation and re-test of the failed phase plus final regression.
