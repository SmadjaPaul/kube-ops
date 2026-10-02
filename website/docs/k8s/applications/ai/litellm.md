---
title: 'LiteLLM Gateway'
---

LiteLLM is the V1 AI gateway. The proxy is deployed from LiteLLM's official OCI Helm chart; Git owns provider/model
routing while PostgreSQL owns runtime identities, virtual keys and spend records.

## Reference implementations

The deployment structure was checked against current public GitOps clusters in October 2026.

- `joshdurbin/home-pi-infrastructure` is the primary structural reference: Argo CD multi-source Application, official
  `litellm-helm` 1.103.2, external CloudNativePG, external Redis and authenticated metrics.
- `wittdennis/gitops-kubernetes` independently uses the official 1.103.2 chart with existing PostgreSQL and Authentik.
- `derio-net/frank` is useful for older operational lessons and migration failures, but its LiteLLM versions are not a
  version authority for this cluster.

The cluster deliberately does not deploy a community LiteLLM operator. The official chart removes the hand-written proxy
Deployment/Service and owns schema migration without adding a new CRD/controller lifecycle.

## Argo / Helm ownership

`k8s/applications/ai/litellm-helm-application.yaml` is a child Argo Application with two sources:

1. `ghcr.io/berriai/litellm-helm:1.103.2`;
2. this Git repository as the values source.

`k8s/applications/ai/litellm/values.yaml` is the proxy authority. The sibling Kustomization owns only dependencies and
policy inputs: namespace, CNPG, Redis, ESO Secrets, Gateway API route and monitoring.

The child Application is placed after those resources with a sync wave. The official chart's Argo PreSync migration Job
runs the database migration once before the proxy Deployment.

## Completion providers

Two production completion providers are authoritative:

- Xiaomi MiMo PAYG: primary coding/reasoning path.
- Alibaba Cloud Model Studio PAYG in Frankfurt: low-cost research and independent review.

Interactive Xiaomi Token Plan and Alibaba Token/Coding Plan credentials must not be used as automated LiteLLM backend
credentials. The cluster consumes production API credentials only.

Cloudflare Workers AI remains temporarily for the existing Qwen embedding lane. Tavily remains a search-tool dependency
for Perplexica; neither is a completion provider.

## Stable model lanes

Clients depend on these names rather than upstream model IDs:

| Lane | Purpose | Backing model |
| --- | --- | --- |
| `research` | cheap lookup/extraction/research | Alibaba Qwen3.8 Flash, non-thinking |
| `fast` | inexpensive general work | MiMo V2.6 Flash, thinking disabled |
| `code` | implementation/coding agents | MiMo V2.6 Pro |
| `reasoning` | difficult cross-system reasoning | MiMo V2.6 Pro |
| `review` | independent second-family review | Alibaba Qwen3.8 Max, high reasoning |
| `auto` | choose a complexity/cost lane | Jev 1.13 through OpenRouter -> lanes above |

`qwen3-embedding-0.6b` remains the stable embedding name.

Paperclip, OpenClaw and GPT Researcher use the stable lanes. This lets the backing model change after cost/quality
measurement without editing every client.

## Decision router: Jev with self-hosted alternatives evaluated

The `auto` lane uses LiteLLM's native JEV classifier client against Jev 1.13 through OpenRouter's TypeSafe-compatible
System One API. OpenRouter is used only for the classification call; MiMo and Alibaba remain the completion providers.

```text
LiteLLM auto
  |
  | POST /v1/systemone
  v
OpenRouter Decisions / Jev 1.13
  |
  +-- SIMPLE    -> research
  +-- MEDIUM    -> fast
  +-- COMPLEX   -> code
  +-- REASONING -> reasoning
```

Only the current user turn is classified; prior conversation turns and assistant output are excluded. The classifier has a
3-second timeout, circuit breaker and LiteLLM heuristic fallback. Callers can always bypass this extra trust boundary by
requesting an explicit lane.

The October 2026 self-hosted System One ecosystem was reviewed before choosing this baseline:

- **Von**: 395M, CPU/OpenVINO, excellent deployment ergonomics and TypeSafe wire compatibility, but its model card is
  explicitly English-only. It remains attractive for an English-only or fine-tuned future deployment.
- **Laya**: 322M multilingual checkpoint for 100+ languages and native Jev-compatible `laya-serve`. It is the most
  interesting local candidate for French/English traffic, but current independent routing/decision benchmarks do not yet
  justify making it the V1 authority.
- **Kev**: the strongest open Jev-like family reviewed (0.8B/4B/9B/27B), but the useful 4B+ sizes are better matched to a
  GPU or Apple Silicon host than this cluster's CPU-only AOOSTAR.
- **vLLM Semantic Router**: has a mature Kubernetes/Helm story but is a separate routing control plane rather than a small
  Jev-compatible classifier; running it beside LiteLLM would duplicate policy and increase operational complexity.

The model endpoint remains replaceable. A future local classifier only needs to prove lower cost per successful task on a
representative French/English corpus, then replace the JEV base URL without changing client-facing lanes.

## Provider credentials

Provider values never belong in Git. Before rollout, Doppler `cluster/prd` must contain:

```text
APP_XIAOMI_MIMO_API_KEY
APP_ALIBABA_MODEL_STUDIO_API_KEY
APP_ALIBABA_MODEL_STUDIO_BASE_URL
APP_OPENROUTER_API_KEY
```

The OpenRouter key is used only as the bearer credential for Jev classification. The Alibaba key and base URL must belong
to the same Frankfurt workspace.

ESO maps those values into `litellm-provider-secrets`; clients receive only LiteLLM virtual keys.

## Security posture

LiteLLM is a privileged credential broker. The target therefore:

- keeps provider credentials server-side;
- stores neither prompt nor response bodies in message/spend logs;
- redacts API-key metadata and exception messages;
- fails closed when the policy database is unavailable;
- requires authentication on the Prometheus endpoint;
- uses pre-call validation;
- keeps model definitions in Git (`store_model_in_db: false`);
- permits provider egress only to required FQDNs;
- runs one proxy replica with non-root UID, RuntimeDefault seccomp and all Linux capabilities dropped.

The chart's migration/startup path still needs writable image paths in this release, so `readOnlyRootFilesystem` is not
enabled on the Helm-managed proxy. This is an explicit upstream compatibility tradeoff, not an implicit security
regression. Re-enable it only after a chart/image canary proves both migration and steady-state startup work.

The HTTPRoute still attaches to both internal and external Gateways. Do not remove the existing public attachment until
the LAN-only path is proven at runtime, per the repository migration contract.

## Identity

The Admin UI uses Authentik OIDC. Runtime consumers use separate LiteLLM virtual keys with model allowlists, budgets and
rate limits; they never receive provider credentials.

A later identity phase may replace in-cluster long-lived virtual keys with projected Kubernetes ServiceAccount JWTs
validated by Envoy. Authentik Agent/OBO is reserved for the later case where an AI agent acts on behalf of a human user in
downstream applications.

## Database, cache and migrations

The existing CNPG cluster remains authoritative:

```text
litellm-postgresql-restored-rw.litellm.svc.cluster.local:5432/app
```

CNPG backup/restore remains unchanged. The existing ephemeral Redis Deployment remains the response/router cache.

The official chart owns the proxy schema migration through its bounded Argo PreSync Job. Proxy pods no longer carry the
custom `wait-for-postgresql` init container or perform independent schema ownership.

## Observability

LiteLLM emits Prometheus metrics with authentication enabled. A repository-owned ServiceMonitor scrapes the chart Service
using `LITELLM_MASTER_KEY` from the existing secret rather than opening an unauthenticated metrics endpoint.

Cost evaluation must correlate:

- requested stable lane;
- resolved provider/model;
- classifier decision/fallback;
- input/output/cache tokens;
- task validation result.

The optimization target is cost per successful task, not cost per raw token.

## Rollout gates

Do not merge until the external MiMo, Alibaba and OpenRouter credentials exist in Doppler and ESO can materialize the
provider Secret.

After merge, prove:

1. parent Argo resources are Healthy before the LiteLLM child Application syncs;
2. the chart migration Job completes and proxy readiness is healthy;
3. Authentik Admin UI login works after the LiteLLM session-format upgrade;
4. `research`, `fast`, `code`, `reasoning`, `review` and the embedding lane respond;
5. `auto` correctly routes a representative English and French task set through Jev and falls back to LiteLLM's local heuristic when the decision endpoint is unavailable;
6. explicit lanes work with OpenRouter/Jev unavailable, proving the classifier is not a hard dependency;
7. Paperclip, OpenClaw, Open WebUI, GPT Researcher and Perplexica can reach the Helm Service on port 4000;
8. spend/Prometheus records contain metadata and cost but not prompt bodies.

Static repository validation remains:

```bash
just check
```

Static validation does not prove OCI chart reachability, provider credentials, runtime migrations or classifier quality.
