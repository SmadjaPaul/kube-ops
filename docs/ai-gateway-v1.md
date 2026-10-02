# AI Gateway V1

## Goal

Use LiteLLM as the single model gateway for both Paperclip/OpenCode and OpenWebUI.

Paperclip never receives provider credentials. It receives only a LiteLLM virtual key and calls stable model aliases. Provider credentials, quotas, routing and fallback stay in the LiteLLM namespace.

## Architecture

```
Paperclip / OpenCode ─┐
                     ├─> LiteLLM ─> MiniMax Token Plan
OpenWebUI ────────────┘           ├─> Azure/OpenAI
                                 ├─> Anthropic
                                 └─> TypeSafe JEV classifier
```

## Paperclip role aliases

| Paperclip role | LiteLLM alias | V1 provider |
| --- | --- | --- |
| Engineering Manager | `factory-manager` | MiniMax M3 |
| Researcher | `factory-research` | MiniMax M3 |
| Implementation Engineer | `factory-implement` | MiniMax M3 |
| Reviewer | `factory-review` | Anthropic Claude Sonnet 4.6 |
| QA / Release | `factory-qa` | MiniMax M3 |

The independent reviewer intentionally uses a different provider family from the implementer.

Changing a provider later only changes LiteLLM configuration; Paperclip's role contract stays stable.

## OpenWebUI aliases

| Alias | Purpose | External classifier |
| --- | --- | --- |
| `simple-question` | routine direct answer | no |
| `research` | broader research/synthesis | no |
| `private-research` | explicit classifier-private research | no |
| `agentic` | multi-step/tool-oriented work | no |
| `auto` | convenience complexity routing | TypeSafe JEV |

`private-research` means the prompt bypasses JEV classification. It does not mean the completion model is self-hosted.

The JEV router receives no previous assistant/user turns because the context window is zero.

## MiniMax Token Plan

MiniMax Token Plan is designed for individual developer and coding-agent use and supports OpenAI-compatible tools. V1 therefore places the subscription behind the personal LiteLLM gateway used by this homelab software factory.

Required Doppler keys:

- `APP_MINIMAX_TOKEN_PLAN_API_KEY`
- `APP_MINIMAX_TOKEN_PLAN_API_BASE`

The Base URL is operator supplied from the Token Plan page rather than hard-coded.

If this factory becomes externally served, multi-tenant or SLA-bearing, switch the alias to MiniMax PAYG without changing Paperclip.

## Xiaomi MiMo Token Plan

MiMo Token Plan is deliberately NOT configured behind LiteLLM.

Xiaomi's current Token Plan conditions restrict package quota to programming tools and explicitly prohibit clearly non-coding automated scripts and custom application backends. Putting the token-plan credential behind the shared LiteLLM gateway would cross that boundary.

MiMo can be added to LiteLLM later with a PAYG API key. The Paperclip alias contract does not need to change.

## JEV / Auto Router

`auto` uses the LiteLLM complexity router with TypeSafe JEV:

- SIMPLE -> `simple-question`
- MEDIUM -> `research`
- COMPLEX -> `agentic`
- REASONING -> `agentic`

Required Doppler key:

- `APP_TYPESAFE_API_KEY`

Auto Router is an add-on capability. This PR remains draft until the current LiteLLM entitlement is proven to accept it. If not, remove only the `auto` alias; every explicit capability remains valid.

V1 pins TypeSafe to `jev-1.13.0` for repeatability. Move to `jev-latest` only after re-running the routing evaluation because model upgrades can shift tier probabilities.

## User delegation

`agentic-user-delegated` is not a routing tier.

User delegation must require a valid Authentik RFC 8693 on-behalf-of/token-exchange context and policy. A model classifier must never grant or synthesize authority.

This remains unavailable in V1.

## Runtime gates

Before merge:

1. required MiniMax and TypeSafe Doppler keys exist;
2. LiteLLM 1.103.2 starts under the current restricted security context;
3. database startup/migration succeeds;
4. LiteLLM Authentik SSO still works;
5. all five `factory-*` aliases respond;
6. Paperclip/OpenCode can call only LiteLLM and completes one real issue workflow;
7. explicit OpenWebUI aliases respond;
8. if licensed, `auto` routes representative French and English prompts;
9. `private-research` causes no TypeSafe/JEV request;
10. no prompt bodies are added to spend logs.

## Software Factory V1 definition of done

One real GitHub issue completes:

1. Engineering Manager plans a dependency-aware DAG.
2. Researcher provides evidence if needed.
3. Implementation Engineer creates an isolated branch and patch.
4. Reviewer independently reviews it.
5. Implementation Engineer fixes blocking findings.
6. QA / Release runs acceptance checks.
7. The resulting PR is ready for human merge approval.

Track provider/model, tokens where available, wall-clock duration, review iterations, tests, and final human acceptance. Optimize for cost per accepted validated PR, not only cost per token.

## Non-goals

- no Paperclip upgrade;
- no Business activation;
- no Authentik OBO enablement;
- no MiMo Token Plan behind LiteLLM;
- no home-ops changes.
