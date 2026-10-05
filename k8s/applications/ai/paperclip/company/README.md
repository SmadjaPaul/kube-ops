# Smadja Software Factory company package

Git-native Paperclip company definition for the homelab software factory.

Reference patterns deliberately combined here:

- Paperclip `Superpowers Dev Shop`: small role graph and disciplined plan/build/review/release loop.
- Paperclip `GStack`: QA/release emphasis.
- `Teck-Lab/Teck.Agents`: blocker DAGs, isolated worktrees and parallel-safe leaf execution.
- Compound Engineering: Plan -> Work -> Review -> Compound discipline, reduced to a five-agent V1.

## Import

After Paperclip is healthy and the instance has been claimed by the human admin,
import this folder with Paperclip's supported Company import flow. Keep this
directory as the canonical portable definition; runtime Paperclip state is not
the source of truth for the Company package.

The canonical issue inventory is separate:
`projects/kube-ops/backlog-seed.yaml`. It is reconciled through the repository
adapter in `scripts/paperclip/import-backlog-seed.mjs`; Paperclip's Company
import does not natively import that backlog format.

The V1 intentionally has no scheduled heartbeats. Work is started explicitly
while execution and approval boundaries are being qualified.

## V1 boundaries

- No self-merge. R1 can be merged only after independent review, QA and required CI gates.
- No direct Kubernetes mutation as the normal delivery path.
- The first DOC smoke may use `opencode_local` to prove orchestration without simultaneously changing execution infrastructure.
- `opencode_local` is bootstrap-only for the production factory security model.
- The target execution boundary is Paperclip's first-party Kubernetes sandbox provider, qualified first with one disposable agent before role-by-role migration.
- The production Paperclip Kustomization does not currently activate the sandbox candidate.
- No generic auth fork is introduced merely to make the factory work.
- Model access routes through the existing in-cluster LiteLLM capability aliases.
