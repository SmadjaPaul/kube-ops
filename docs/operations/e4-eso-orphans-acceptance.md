# E4 — ESO, orphans and application acceptance

Evidence collected on 2026-10-08 from the canonical operator kubeconfig and
rechecked on 2026-10-22. This document contains names and statuses only; no
Kubernetes Secret or Doppler Secret value was read.

The ESO-visible authority is the runtime-domain Doppler project `cluster`,
config `prd`, exposed through the `doppler-cluster` ClusterSecretStore. The
bootstrap project `infrastructure/prd` is operator-only and is not read by
ESO. Provisioning or projecting a missing runtime credential therefore belongs
to `homelab-infra/terraform/doppler`; this repository must not add a
placeholder Secret or value.

## ExternalSecrets blocked by missing Doppler keys

The following key names are absent from the ESO-visible `cluster/prd` runtime
domain and are also reported by ESO as failed remote lookups:

| Namespace | ExternalSecret | Missing Doppler key names | Owner role and approval path |
|---|---|---|---|
| `gpt-researcher` | `app-gpt-researcher-litellm-api-key` | `APP_GPT_RESEARCHER_FACTORY_LITELLM_API_KEY` | AI application owner; confirm intended Factory gateway consumer |
| `gpt-researcher` | `gpt-researcher-secrets` | `APP_GPT_RESEARCHER_TAVILY_API_KEY`, `APP_GPT_RESEARCHER_LANGCHAIN_API_KEY` | AI application owner; confirm external-provider billing and scope |
| `invoice-ninja` | `invoice-ninja-mcp` | `APP_INVOICE_NINJA_API_TOKEN`, `APP_INVOICE_NINJA_MCP_OPENCLAW_TOKEN`, `APP_INVOICE_NINJA_MCP_PAPERCLIP_TOKEN` | Business/MCP application owner; confirm each consumer separately |
| `litellm` | `litellm-provider-secrets` | `APP_OPENAI_BASE_URL_1`, `APP_OPENAI_API_KEY_1`, `APP_CLOUDFLARE_WORKERS_API_BASE`, `APP_CLOUDFLARE_WORKERS_API_KEY`, `APP_CEREBRAS_API_KEY`, `APP_OPENAI_BASE_URL_2`, `APP_OPENAI_API_KEY_2`, `APP_MISTRAL_API_KEY`, `APP_ANTHROPIC_API_KEY`, `APP_TAVILY_API_KEY`, `APP_MINIMAX_TOKEN_PLAN_API_KEY`, `APP_MINIMAX_TOKEN_PLAN_API_BASE` | AI provider owner; confirm provider, budget and egress scope per key |
| `media` | `jellyseerr-secrets` | `APP_JELLYSEERR_JELLYFIN_URL`, `APP_JELLYSEERR_JELLYFIN_API_KEY` | Media application owner; confirm Jellyfin endpoint and least-privilege account |
| `media` | `seerr-first-run` | `APP_JELLYSEERR_JELLYFIN_API_KEY`, `APP_SEERR_BOOTSTRAP_ADMIN_PASSWORD` | Media application owner; bootstrap password requires one-time operator handling |
| `open-webui` | `app-openwebui-litellm-api-key` | `APP_OPENWEBUI_FACTORY_LITELLM_API_KEY` | AI application owner; confirm Factory gateway audience |
| `open-webui` | `openwebui-ai-backend-keys` | `APP_OPENWEBUI_FACTORY_LITELLM_API_KEY`, `APP_OPENCLAW_TALOS_PERSONAL_GATEWAY_TOKEN` | AI/platform owner; confirm OpenClaw consumer and token audience |
| `renovate` | `renovate` | `APP_RENOVATE_GITHUB_TOKEN` | Platform maintenance owner; confirm repository scope and read-only permissions |
| `security-system` | `falco-slack-webhook` | `FALCO_SLACK_WEBHOOK_URL` | Retired on 2026-10-18 after static/live consumer review; no active destination remains |

The `litellm` provider key names are intentionally retained in the row rather
than copied into a second secret inventory. The owner column names a role, not a
person and is an approval request, not evidence that a credential exists. D did
not read, create, rotate or infer any value. The application owner must confirm
the row and provide the value through the approved Doppler workflow; D only
rechecks the ExternalSecret condition afterward.

These are credential-provisioning gates, not Git manifest defects. No
placeholder values must be added to Git.

The `security-system/falco-slack-webhook` ExternalSecret was removed from the
desired state on 2026-10-18 after confirming that no Deployment, StatefulSet,
DaemonSet, Job or CronJob references its target Secret and that Falco remains
running without it. The shared `doppler-cluster` SecretStore was not changed.

## Application acceptance

Machine evidence is bounded to workload readiness, EndpointSlice readiness,
HTTPRoute conditions, PVC state and ESO conditions.

| Application | Machine acceptance | Human acceptance |
|---|---|---|
| Home Assistant | PASS: pod and EndpointSlice ready; PVC bound; ESO ready; internal and external HTTPRoute accepted with resolved references | HUMAN_GATE: real Authentik login/onboarding/dashboard journey not run from an external browser |
| Sure | PASS: web, worker, Redis and CNPG ready; PVCs bound; ESO ready; Route accepted with resolved references | HUMAN_GATE: real OIDC login and first-user/admin promotion not performed |
| ntfy | PASS: pod and EndpointSlice ready; PVC bound; ESO ready; Routes accepted with resolved references | HUMAN_GATE for real OIDC/user workflow |
| Paperless | PASS: web, Redis and CNPG ready; PVCs bound; ESO ready; Route accepted with resolved references | HUMAN_GATE for real OIDC/user workflow |
| Renovate | BLOCKED: CronJob exists, but ESO is not ready and the current pod cannot create its container because Secret `renovate` is absent | HUMAN_ACTION required to provision `APP_RENOVATE_GITHUB_TOKEN` |

Home Assistant and Sure are not blocked by Kubernetes readiness; their USER
level remains unproven. The repository contains no literal `WAITING_OPERATOR`
status marker. The operator gates are the missing Doppler keys above and the
human browser workflows.

## Orphan classification and pruning proposal

The preceding audit reported 906 catalog orphans. The current live
`apps-catalog` condition reports **910** orphaned resources, so the two counts
must not be conflated. No object was deleted.

Until a per-object Argo resource-tree export is supplied, the safe
classification is conservative:

| Class | Classification rule | Action now |
|---|---|---|
| `GIT_OWNED` | Rendered by the current catalog or another active Git source | Retain; never prune as an orphan |
| `ARGO_OWNED` | Controller child of a current Git-owned resource, identified by owner reference or active tracking | Retain; controller owns lifecycle |
| `RETAINED_STATE` | PVC/PV, database, backup object, application Secret metadata, or other durable state without a current render | Retain; requires data-owner decision and restore evidence |
| `DISABLED_APP` | Resources belonging to intentionally disabled catalog entries such as Actual Budget, Dawarich or Metabase | Retain pending explicit decommission decision |
| `TEMP_DRILL` | Resources created by a named restore/backup drill and still inside its retention window | Retain until drill closure and evidence capture |
| `STALE_SAFE_CANDIDATE` | Only after the object-level inventory proves no owner, no active Argo tracking, no durable data, no active route and an approved retention expiry | Candidate only; human approval required |
| `UNKNOWN` | Anything not proven by the preceding rules | Retain; do not investigate by deletion |

The aggregate warning alone cannot safely assign individual objects to these
classes. Therefore the current 910-object set is `UNKNOWN_DO_NOT_TOUCH` until
Argo resource-tree data or an equivalent object-level inventory is attached.

### Separate human-approval pruning procedure

No deletion command is part of this repository change. A future pruning PR may
proceed only after a human approves an attached, immutable inventory containing
for every object: API group/kind, namespace/name, UID, creation timestamp,
owner references, Argo tracking metadata, PVC/Secret/database classification,
last-seen evidence, proposed class and rollback/restore disposition.

The approval must explicitly name the exact object UIDs and confirm that the
set excludes `GIT_OWNED`, `ARGO_OWNED`, `RETAINED_STATE`, `DISABLED_APP` and
`TEMP_DRILL`. The cleanup PR must then contain only the approved
`STALE_SAFE_CANDIDATE` set, with a pre-delete export and a post-delete Argo
orphan-count check. A second human approval is required for any object whose
class changes to `UNKNOWN`.

## Human actions

1. Provision or project the missing runtime key names listed above through the
   approved `homelab-infra/terraform/doppler` workflow so they become
   available in `cluster/prd`; never paste their values into Git or this
   report.
2. For Home Assistant, run the external-browser Authentik login/onboarding/
   dashboard acceptance.
3. For Sure, run the external-browser OIDC login and explicitly approve the
   first-user `super_admin` promotion procedure.
4. Approve an object-level orphan inventory before any pruning proposal is
   converted into a deletion PR.

## Rollback

This commit changes documentation only. Rollback is `git revert` of the
documentation commit; no workload or cluster state is changed.
