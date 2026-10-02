---
title: 'LiteLLM Gateway'
---

LiteLLM is the V1 model gateway. Clients use one OpenAI-compatible endpoint and stable workload-facing model names;
provider credentials remain server-side and are delivered through Doppler -> External Secrets Operator.

## Target architecture

Two completion providers are authoritative for V1:

- Xiaomi MiMo PAYG is the primary coding/reasoning provider.
- Alibaba Cloud Model Studio PAYG in Frankfurt is the research and independent-review provider.

TypeSafe JEV is a classifier dependency for the `auto` lane, not a completion provider. OpenRouter is deliberately not a
V1 dependency; it remains an optional future long-tail/emergency route.

Interactive Alibaba Token Plan / Coding Plan credentials must not be used as LiteLLM backend credentials. Alibaba
documents those plans for interactive coding tools and excludes automated application backends. Use a Model Studio
production API key instead.

## Ownership

Git owns the gateway policy:

- `k8s/applications/ai/litellm/proxy_server_config.yaml` owns models, routing and proxy policy.
- `k8s/applications/ai/litellm/kustomization.yaml` pins the rendered LiteLLM image.
- `k8s/applications/ai/litellm/litellm-provider-secrets.yaml` maps externally provisioned credentials from Doppler.
- PostgreSQL stores virtual keys, users and spend records.
- Redis is ephemeral cache/router state; it is not an authority.

Provider credentials are operator-provisioned external inputs. They are never generated in `kube-ops` and their values
must never enter Git, prompts, logs or PR comments.

## Stable model lanes

Clients depend on these names instead of provider/model identifiers:

| Lane | Purpose | Target |
| --- | --- | --- |
| `research` | cheap lookup, extraction and bounded research | Alibaba Qwen3.8 Flash, non-thinking |
| `fast` | inexpensive general work | MiMo V2.6 Flash, thinking disabled |
| `code` | implementation and coding-agent work | MiMo V2.6 Pro |
| `reasoning` | difficult cross-system reasoning | MiMo V2.6 Pro |
| `review` | independent second-family review | Alibaba Qwen3.8 Max, high reasoning |
| `auto` | choose a cost/complexity tier | TypeSafe JEV -> lanes above |

The lane names are the compatibility contract. Backing models may change after measured cost-per-successful-task evidence
without changing clients.

## Auto routing and privacy

`auto` uses LiteLLM's built-in Auto Router with TypeSafe JEV `jev-1.13.0`:

- SIMPLE -> `research`
- MEDIUM -> `fast`
- COMPLEX -> `code`
- REASONING -> `reasoning`
- JEV timeout: 3 seconds
- circuit breaker: enabled, 30-second cooldown
- classifier failure: local heuristic fallback
- prior-turn classifier context: disabled
- model/session affinity: one hour

Only calls to `auto` send classification input to TypeSafe. Explicit calls to `research`, `fast`, `code`,
`reasoning` or `review` bypass JEV. Use an explicit lane when the additional classifier trust boundary is not
appropriate.

Session and deployment affinity are enabled because coding-agent requests repeatedly reuse large prefixes. This preserves
provider-side prompt-cache locality and avoids unnecessary model churn during tool loops. Responses API deployment
affinity remains enabled for `previous_response_id` continuity.

## Credential contract

Before this target routing can be rolled out, Doppler `cluster/prd` must contain the externally provisioned values that
ESO maps into the LiteLLM provider Secret:

```text
APP_XIAOMI_MIMO_API_KEY
APP_ALIBABA_MODEL_STUDIO_API_KEY
APP_ALIBABA_MODEL_STUDIO_BASE_URL
APP_TYPESAFE_API_KEY
```

The Alibaba base URL must point at the same Frankfurt workspace in which its API key was created. Do not put any of these
values in Git.

The existing providers remain declared during migration so rollback does not depend on recreating historical credentials.
Remove unused provider declarations only after runtime usage proves they are no longer needed.

## Security posture

LiteLLM is a privileged credential broker. V1 therefore uses fail-closed defaults:

- prompt/response bodies are not written to LiteLLM message logs or spend logs;
- API-key data and exception messages are redacted;
- pre-call checks reject invalid/context-incompatible requests before provider spend;
- database unavailability does not bypass virtual-key policy;
- the Prometheus endpoint requires authentication;
- production log level is `INFO`;
- provider keys exist only in the LiteLLM namespace through ESO.

The HTTPRoute currently attaches to both internal and external Gateways. Do not remove the external attachment until the
internal DNS/TLS/backend path is proven at runtime, per the repository migration safety contract.

## Identity

The Admin UI uses Authentik OIDC. Runtime consumers use separate LiteLLM virtual keys, for example Open WebUI, an ops
agent, an infra agent and an operator workstation. Apply model allowlists, budgets and rate limits per identity rather
than sharing the master key.

A later workload-identity phase may replace long-lived in-cluster virtual keys with short-lived Kubernetes ServiceAccount
JWTs validated at Envoy. Authentik Agent/OBO identities are reserved for the later case where an AI agent acts on behalf
of a human user in downstream applications; they are not required for model routing.

## Kubernetes packaging

V1 deliberately uses the current Kustomize-managed raw manifests. Raw manifests are an upstream-supported LiteLLM
deployment path and already fit this repository's Argo ApplicationSet.

Do not add a community LiteLLM operator for V1. The public operators reviewed in October 2026 are young and add CRDs and
another reconciler without improving model cost or identity.

If packaging is revisited, the supported migration candidate is LiteLLM's official Helm chart. Its main concrete benefit
for this homelab is the upstream migration Job / schema-update lifecycle plus native ServiceMonitor/PDB/HPA integration.
That packaging migration is intentionally separate from this provider/routing change.

## Responses API

`responses_api_deployment_check` stays enabled so follow-up requests using `previous_response_id` remain on the
compatible deployment. Response-ID security remains enabled (`DISABLE_RESPONSES_ID_SECURITY=false`).

## Data and observability

PostgreSQL is backed up through the existing CNPG/Barman path. Redis has no persistence because it only carries cache and
router state. Cost accounting must record requested lane plus resolved provider/model and JEV classifier spend so routing
can be evaluated on cost per successful task rather than raw token price.

## Upgrade notes

The V1 desired state pins LiteLLM `v1.103.2`. The move from the old 1.88 line crosses database migrations and the
1.103.1 session-token change. Admin UI / Lite CLI sessions created on the old version must authenticate again after
rollout. LiteLLM virtual keys, the master key and stored provider credentials are not intentionally rotated.

## Merge and runtime gates

Do not merge the provider-routing target until the four Doppler credential names above exist and ESO can materialize the
provider Secret.

After rollout, prove:

1. Argo reconciles the desired revision and LiteLLM/CNPG are healthy.
2. Authentik Admin UI login works after re-authentication.
3. Direct probes succeed through `research`, `fast`, `code`, `reasoning` and `review`.
4. `auto` classifies representative simple, coding and hard-reasoning tasks; JEV failures fall back to the heuristic.
5. MiMo multi-turn tool use preserves required reasoning content.
6. Spend records contain cost/metadata but no prompt bodies.
7. Measured cost per successful task is captured before changing lane assignments.

Static validation:

```bash
just check
kubectl kustomize k8s/applications/ai/litellm
```

A successful render does not prove provider reachability, credentials, migrations, routing or user authentication.
