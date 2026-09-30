# Agentic platform V1 — runtime acceptance runbook

This runbook is intentionally operational and evidence-driven. The goal is not to prove the design is perfect; it is to make the first naive implementation real, observe what breaks, and fix only demonstrated failures.

## Guardrails

- Work only from PR #110 and its branch.
- Do not merge until the acceptance matrix below passes or every remaining failure is documented.
- Do not recreate the cluster.
- Do not bypass TLS with `-k`.
- Do not put secret values in Git, logs, comments, or reports.
- Do not mutate Kubernetes imperatively except for reversible diagnostics or an explicitly documented temporary probe.
- Durable fixes go through Git -> Argo CD -> Kubernetes.
- Preserve the local-first baseline: `auth.smadja.dev`, `chat.smadja.dev`, and `hassio.smadja.dev` must continue to resolve privately to `10.0.20.192`.

## Phase 0 — preflight

Record:

```
TEST_HEAD_SHA=
ARGO_BASELINE=
NODE_READY=
LOCAL_FIRST_BASELINE=
```

Verify required Doppler keys exist without reading their values:

- `APP_PAPERCLIP_BETTER_AUTH_SECRET`
- `APP_PAPERCLIP_SECRETS_MASTER_KEY`
- `APP_PAPERCLIP_LITELLM_API_KEY`
- existing OpenClaw keys already used by the cluster

If a required Paperclip key is missing, stop only that workstream and report the exact key name. Do not invent placeholder secrets.

## Phase 1 — static/render validation

From the PR branch:

- run the repository's canonical validation command(s);
- render the affected Kustomize trees;
- verify both operator Applications render;
- verify `Instance` and `OpenClawInstance` resources are present;
- verify no plaintext `kind: Secret` was introduced for application credentials;
- verify no new public Paperclip route exists.

Record:

```
STATIC_VALIDATION=
PAPERCLIP_RENDER=
OPENCLAW_RENDER=
SECRET_SCAN=
PUBLIC_EXPOSURE_CHECK=
```

## Phase 2 — operator reconciliation

After the branch is intentionally deployed through Argo:

Verify:

- `paperclip-operator` Application Healthy/Synced;
- `openclaw-operator` Application Healthy/Synced;
- CRDs Established;
- operator pods Ready;
- no CrashLoopBackOff;
- no webhook/CRD admission errors.

Record:

```
PAPERCLIP_OPERATOR=
OPENCLAW_OPERATOR=
PAPERCLIP_CRD=
OPENCLAW_CRD=
```

## Phase 3 — Paperclip dependencies

Verify:

- ExternalSecret is `SecretSynced=True`;
- CNPG cluster `paperclip-postgresql` is Ready;
- app secret `paperclip-postgresql-app` exists;
- ObjectStore is accepted;
- WAL archiving reaches Hetzner successfully;
- one manual/base backup can complete successfully.

Do not print DATABASE_URL or S3 credentials.

Record:

```
PAPERCLIP_ESO=
PAPERCLIP_CNPG=
PAPERCLIP_WAL=
PAPERCLIP_BASE_BACKUP=
```

## Phase 4 — Paperclip runtime

Verify:

- Paperclip `Instance` reaches Ready;
- Service has healthy endpoints;
- operator-created HTTPRoute is Accepted and Programmed on `Gateway/internal`;
- LAN DNS resolves `paperclip.smadja.dev` to `10.0.20.192`;
- public resolver does not resolve it to the internal VIP;
- normal TLS succeeds without bypass;
- UI/login endpoint responds.

Then perform the supported first-admin board-claim flow with the human only if interactive login is required.

Record:

```
PAPERCLIP_INSTANCE=
PAPERCLIP_ROUTE=
PAPERCLIP_PRIVATE_DNS=
PAPERCLIP_TLS=
PAPERCLIP_BOARD_CLAIM=
```

## Phase 5 — model path

From Paperclip/OpenCode, perform one minimal model request through LiteLLM.

Prove from runtime evidence that the request path is:

```
Paperclip/OpenCode -> litellm.litellm.svc -> configured upstream model
```

The agent must not contain provider master credentials.

Record:

```
PAPERCLIP_LITELLM=
MODEL_USED=
DIRECT_PROVIDER_SECRET_PRESENT=no
```

## Phase 6 — company import

Import `k8s/applications/ai/paperclip/company` with Paperclip's supported company import flow.

Verify these five roles exist:

- Engineering Manager
- Researcher
- Implementation Engineer
- Reviewer
- QA & Release Engineer

Verify the two Git projects exist:

- `SmadjaPaul/kube-ops`
- `SmadjaPaul/homelab-infra`

Keep all V1 heartbeats disabled.

Record:

```
COMPANY_IMPORT=
AGENTS_5_OF_5=
PROJECTS_2_OF_2=
HEARTBEATS_DISABLED=
```

## Phase 7 — first real delegated task

Create one harmless task whose output is a tiny documentation-only PR.

The Engineering Manager must:

1. create at least two child tasks;
2. make dependencies explicit;
3. delegate research and implementation to different agents;
4. route the result through Reviewer;
5. route final verification through QA & Release;
6. open a PR;
7. not merge it.

Preferred task: improve one existing README with a clearly factual, non-production change.

Record:

```
DAG_CREATED=
DELEGATION=
INDEPENDENT_REVIEW=
QA=
TEST_PR_URL=
SELF_MERGE=no
```

## Phase 8 — OpenClaw operator migration

Verify:

- `OpenClawInstance/openclaw` Ready;
- the existing Doppler-backed gateway token is reused;
- operator-created Service, HTTPRoute and ServiceMonitor exist;
- `openclaw.smadja.dev` works through the expected Gateway path;
- LiteLLM call succeeds;
- Slack smoke test succeeds if Slack is currently configured;
- workspace persistence survives one pod restart;
- old StatefulSet-owned PVCs were not automatically deleted.

Record:

```
OPENCLAW_INSTANCE=
OPENCLAW_GATEWAY_TOKEN_REUSED=
OPENCLAW_HTTP=
OPENCLAW_LITELLM=
OPENCLAW_SLACK=
OPENCLAW_PERSISTENCE=
LEGACY_PVCS_PRESERVED=
```

## Phase 9 — regression

Re-run the already-proven local-first probes:

- `auth.smadja.dev` -> `10.0.20.192`, TLS normal;
- `chat.smadja.dev` -> `10.0.20.192`, TLS normal;
- `hassio.smadja.dev` -> `10.0.20.192`, TLS normal.

Verify no new unintended public route was added for Paperclip.

Record:

```
AUTHENTIK_LOCAL=
OPENWEBUI_LOCAL=
HOME_ASSISTANT_LOCAL=
PAPERCLIP_PUBLIC_BYPASS=
LOCAL_FIRST_REGRESSION=
```

## Fix loop

For every failure:

1. capture the smallest useful runtime evidence;
2. identify whether the failure is desired-state, operator behavior, secret delivery, networking, storage, application config, or upstream bug;
3. make the smallest durable Git fix on the PR branch;
4. let Argo reconcile;
5. rerun only the failed phase plus the final regression phase;
6. append the evidence to the PR.

Do not introduce kagent, Honcho, a new vector database, Argo Workflows, a new sandbox platform, or a new auth proxy while fixing this V1 unless a demonstrated blocker cannot be solved with the existing stack.

## Completion matrix

The PR is ready for human review when:

```
STATIC_VALIDATION=PASS
PAPERCLIP_OPERATOR=PASS
OPENCLAW_OPERATOR=PASS
PAPERCLIP_CNPG=PASS
PAPERCLIP_WAL=PASS
PAPERCLIP_INSTANCE=PASS
PAPERCLIP_PRIVATE_DNS=PASS
PAPERCLIP_TLS=PASS
PAPERCLIP_LITELLM=PASS
COMPANY_IMPORT=PASS
DAG_CREATED=PASS
INDEPENDENT_REVIEW=PASS
QA=PASS
SELF_MERGE=no
OPENCLAW_INSTANCE=PASS
OPENCLAW_LITELLM=PASS
OPENCLAW_PERSISTENCE=PASS
AUTHENTIK_LOCAL=PASS
OPENWEBUI_LOCAL=PASS
HOME_ASSISTANT_LOCAL=PASS
LOCAL_FIRST_REGRESSION=PASS
BLOCKERS=none
```

If a field cannot pass because of an upstream defect, report the upstream issue/link, exact observed failure, workaround options, and keep the PR draft.
