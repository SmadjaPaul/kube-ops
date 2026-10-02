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

## Why MiMo bypasses LiteLLM

Xiaomi's Token Plan is explicitly intended for programming tools such as OpenCode and OpenClaw. The same terms prohibit using Token Plan quota as a general custom-application backend or automated-script API.

Paperclip therefore launches OpenCode with the MiMo Token Plan configured as an OpenCode provider. Do not copy this credential into the shared LiteLLM gateway.

If the factory later needs MiMo as a general backend, use MiMo PAYG credentials instead.

## MiniMax V1

The existing MiniMax subscription key is used only through the OpenCode harness in this PR. MiniMax recommends PAYG for production workloads; V1 is a personal homelab software factory, not a production multi-tenant API.

If this workload becomes externally served or SLA-bearing, migrate the factory provider to PAYG without changing Paperclip's role contract.

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
