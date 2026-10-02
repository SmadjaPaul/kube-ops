# OpenWebUI intent routing V1

## Scope

OpenWebUI continues to use LiteLLM as its OpenAI-compatible gateway. This V1 adds stable capability names and one optional JEV-backed `auto` model without changing the client integration.

## Models exposed to OpenWebUI

| Model | Purpose | JEV/OpenRouter sees the request |
| --- | --- | --- |
| `simple-question` | direct informational answer | no |
| `research` | broader research/synthesis | no |
| `private-research` | research that must bypass the external classifier | no |
| `agentic` | multi-step/tool-oriented work | no |
| `auto` | convenience router for ordinary non-private chat | yes, current request classification |

The name `private-research` describes the classifier boundary only. Its completion still uses the configured external completion provider. It is not a claim that inference is self-hosted.

## JEV boundary

`auto` uses the LiteLLM JEV classifier with no prior-turn context:

- SIMPLE -> `simple-question`
- MEDIUM -> `research`
- COMPLEX -> `agentic`
- REASONING -> `agentic`

The built-in classifier is intentionally used without custom tier instructions. Custom business semantics must not be smuggled into an unsupported configuration.

If JEV/OpenRouter is unavailable, `auto` fails over to `agentic`. Explicit model selections never call JEV.

## Privacy

Do not use `auto` for prompts that must not be sent to the classifier. Select `private-research` explicitly.

The classifier receives no previous conversation turns because `classifier_context_window_size` is zero.

## User delegation

User delegation is an authorization concern, not a model-routing label.

A future `agentic-user-delegated` capability may only be enabled when the request carries a valid Authentik on-behalf-of/token-exchange context that preserves both subject user and actor identity and passes policy. JEV must never create or elevate that authority.

Until that identity path is implemented:

`agentic-user-delegated = unavailable`

## Runtime gates

This change stays draft until all of the following are proven:

1. LiteLLM 1.103.2 starts under the existing restricted security context.
2. Existing database migration/startup completes.
3. Existing LiteLLM SSO still works after re-authentication.
4. Explicit models `simple-question`, `research`, `private-research`, and `agentic` respond.
5. `auto` routes representative French and English prompts.
6. OpenRouter/JEV outage falls back to `agentic`.
7. Explicit `private-research` produces no JEV/OpenRouter request.
8. Existing OpenWebUI and application clients still work.
9. No prompt body is added to spend logs.

## Follow-up

The official LiteLLM Helm migration remains a separate change. Do not combine packaging migration with this routing/runtime proof.
