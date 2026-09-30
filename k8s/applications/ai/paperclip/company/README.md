# Smadja Software Factory company package

Git-native Paperclip company definition for the homelab software factory.

Reference patterns deliberately combined here:

- Paperclip `Superpowers Dev Shop`: small role graph and disciplined plan/build/review/release loop.
- Paperclip `GStack`: QA/release emphasis.
- `Teck-Lab/Teck.Agents`: blocker DAGs, isolated worktrees and parallel-safe leaf execution.
- Compound Engineering: Plan → Work → Review → Compound discipline, reduced to a five-agent V1.

## Import

After Paperclip is healthy and the instance has been claimed by the human admin, import this folder with Paperclip's official company import flow. Keep this directory as the canonical portable definition; runtime Paperclip state is not the source of truth for the company package.

The V1 intentionally has no scheduled heartbeats. Work is started explicitly/on-demand while the current Paperclip heartbeat burst regression is unresolved.

## V1 boundaries

- No self-merge.
- No direct Kubernetes mutation as the normal delivery path.
- No Paperclip Kubernetes sandbox yet.
- No generic OIDC patch/fork; Paperclip remains internal-only until upstream generic OIDC lands.
- Model access routes through the existing in-cluster LiteLLM.
