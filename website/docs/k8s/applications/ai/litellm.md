---
title: 'LiteLLM Gateway'
---

LiteLLM is the V1 model gateway. Clients use one OpenAI-compatible endpoint and stable workload-facing model names;
provider credentials remain server-side and arrive through Doppler -> External Secrets Operator.

## Ownership

Git owns the gateway configuration:

- `k8s/applications/ai/litellm/proxy_server_config.yaml` owns models, routing and proxy policy.
- `k8s/applications/ai/litellm/kustomization.yaml` pins the rendered LiteLLM image.
- `k8s/applications/ai/litellm/litellm-provider-secrets.yaml` maps provider credentials from Doppler.
- PostgreSQL stores virtual keys, users and spend records.
- Redis is an ephemeral cache/router-state dependency; it is not an authority.

Do not give provider API keys directly to Open WebUI, coding agents, CI jobs or operator machines. They should receive a
LiteLLM virtual key scoped to their workload instead.

## Stable model lanes

Clients should prefer the stable lane names instead of provider/model identifiers:

| Lane | V1 purpose | Current backing model |
| --- | --- | --- |
| `research` | cheap lookup, extraction and bounded research | GPT-5 nano |
| `fast` | inexpensive general work | GPT-5 mini |
| `code` | implementation and coding-agent work | GPT-5.3 Codex |
| `reasoning` | difficult cross-system reasoning | GPT-5.4 |
| `review` | independent second-family review | Claude Sonnet 4.6 |
| `auto` | complexity routing when the caller does not know the tier | built-in heuristic router |

`auto` classifies only complexity. Coding and independent review remain explicit so a cheap classifier cannot silently
change the security/review semantics of a task. Session affinity is enabled on the auto router to avoid model churn during
agent loops.

These lane names are the compatibility contract. Their backing providers can change later without changing clients.
MiMo, QwenCloud or OpenRouter should be added behind these lanes only after their credentials, usage terms and runtime
probes are ready.

## Security posture

The gateway is a privileged credential broker. V1 therefore uses the following fail-closed defaults:

- prompt/response bodies are not written to LiteLLM message logs or spend logs;
- API-key data and exception messages are redacted;
- pre-call checks reject invalid/context-incompatible requests before provider spend;
- database unavailability does not bypass virtual-key policy;
- the Prometheus endpoint requires authentication;
- production log level is `INFO`;
- provider keys exist only in the LiteLLM namespace through ESO.

The HTTPRoute currently attaches to both the internal and external Gateways. Do not remove the external attachment until
the internal DNS/TLS/backend path has been proven at runtime, per the repository migration safety contract.

## Authentication and identity

The Admin UI uses Authentik OIDC. Runtime consumers should use separate LiteLLM virtual keys, for example one key for
Open WebUI, one for an ops agent, one for an infra agent, and one for an operator workstation. Apply model allowlists,
budgets and rate limits per key/team rather than sharing the master key.

A future workload-identity phase may replace long-lived in-cluster virtual keys with short-lived Kubernetes
ServiceAccount JWTs validated at Envoy. That is deliberately not required for V1.

## Responses API

`responses_api_deployment_check` remains enabled so follow-up requests using `previous_response_id` stay on the
compatible upstream deployment. Response-ID security remains enabled
(`DISABLE_RESPONSES_ID_SECURITY=false`).

## Data and observability

PostgreSQL is backed up through the existing CNPG/Barman path. Redis has no persistence because it only carries cache and
router state. The current `PodMonitor` in this application monitors PostgreSQL; LiteLLM request/spend metrics are emitted
by the Prometheus callback but are not yet scraped by a dedicated LiteLLM monitor.

Cost accounting should use requested lane plus resolved provider/model. This lets routing changes be evaluated on
cost-per-successful-task rather than raw token price.

## Upgrade notes

The V1 desired state pins LiteLLM `v1.103.2`. The move from the old 1.88 line crosses database migrations and the
1.103.1 session-token change. After rollout, Admin UI / Lite CLI sessions created on the old version must authenticate
again. LiteLLM virtual keys, the master key and stored provider credentials are not intentionally rotated by this change.

Before declaring the upgrade complete, prove:

1. Argo reconciles the desired revision.
2. LiteLLM readiness is healthy and PostgreSQL migrations complete.
3. Authentik Admin UI login works again.
4. A virtual-key request succeeds through at least one stable lane.
5. `auto` routes one simple and one complex probe to the expected tiers.
6. Spend records contain metadata/cost but no prompt bodies.

## Validation

Run:

```bash
just check
kubectl kustomize k8s/applications/ai/litellm
```

Runtime evidence is required after merge; a successful render does not prove provider reachability, migrations, routing
or user authentication.
