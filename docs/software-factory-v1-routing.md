# Software Factory V1 routing

## Goal

Keep the first autonomous software-factory loop small, reviewable and cheap while preserving independent review.

Paperclip remains the orchestrator. OpenCode remains the coding harness. Coding-plan credentials are consumed directly by OpenCode rather than relayed through LiteLLM.

## V1 role mapping

| Paperclip role | OpenCode provider/model | Rationale |
| --- | --- | --- |
| Engineering Manager | MiniMax / MiniMax-M3 | long-context planning and agentic orchestration |
| Researcher | MiniMax / MiniMax-M3 | broad research and synthesis |
| Implementation Engineer | Xiaomi MiMo / mimo-v2.6-pro | coding-agent path explicitly supported by MiMo Token Plan |
| Reviewer | MiniMax / MiniMax-M3 | independent provider family from the implementer |
| QA / Release Engineer | MiniMax / MiniMax-M3 | validation and release evidence |

The implementation agent and reviewer intentionally use different provider families.

## Credential boundary

No provider value is stored in Git.

Doppler `cluster/prd` is expected to provide:

- `APP_MINIMAX_TOKEN_PLAN_API_KEY`
- `APP_XIAOMI_MIMO_TOKEN_PLAN_API_KEY`

ESO maps these to the Paperclip runtime Secret.

## Why the Token Plans are direct OpenCode providers

Both Xiaomi MiMo Token Plan and MiniMax Token Plan explicitly support AI coding/agent tools. MiMo documents OpenCode/OpenClaw-class integrations and provides a dedicated regional Token Plan API key and base URL. MiniMax likewise supports third-party OpenAI-compatible coding tools with a Token Plan subscription key.

Paperclip therefore launches OpenCode with the two Token Plans configured directly as OpenCode providers. This keeps the subscription boundary aligned with the providers' documented coding-tool path and avoids turning LiteLLM into an unnecessary relay for the Software Factory V1.

MiMo Europe uses the package-specific OpenAI-compatible endpoint:
`https://token-plan-ams.xiaomimimo.com/v1`.

MiniMax Token Plan uses its subscription key with the OpenAI-compatible MiniMax endpoint.

Both providers describe Token Plans as developer/coding-agent products rather than production API capacity. If the factory later becomes externally served, multi-tenant, or SLA-bearing, migrate the relevant provider to PAYG without changing Paperclip's role contract.

## Definition of done

A factory run is successful only when one real GitHub issue completes:

1. Engineering Manager creates a dependency-aware plan.
2. Researcher supplies evidence if required.
3. Implementation Engineer creates an isolated branch and patch.
4. Reviewer independently reviews the patch.
5. Implementation Engineer addresses blocking findings.
6. QA / Release Engineer runs acceptance checks.
7. A PR is ready for human merge approval.

Record at least:

- provider/model by role
- input/output tokens where available
- wall-clock duration
- review iterations
- tests/checks
- final human acceptance
- estimated cost or subscription quota consumed

The optimization target is cost per accepted, validated PR rather than price per million tokens.

## Non-goals

This change does not:

- upgrade Paperclip;
- enable heartbeat/background loops;
- merge LiteLLM PR #132;
- add Authentik on-behalf-of delegation;
- give an agent permission to impersonate a user;
- activate Business workloads.

User delegation is a separate authorization capability and must require a real Authentik OBO context.
