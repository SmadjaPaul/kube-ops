# Software Factory capability contract

This file defines the intended least-privilege boundary for each Paperclip role.
Prompts are not a security boundary. Runtime credentials, connectors, shell
access and Kubernetes RBAC must eventually enforce the same matrix.

| Role | Git write | GitHub write | Kubernetes | Research tools | Runtime/browser | Merge authority |
|---|---|---|---|---|---|---|
| Engineering Manager | no | no | metadata/read only if required | optional | no | no |
| Researcher | no | no | none | yes | no | no |
| Implementation Engineer | branch/worktree only | branch + PR | read-only | on-demand | limited diagnostics | no self-merge |
| Reviewer | no | review/read only | read-only if evidence requires it | optional | limited | no |
| QA & Release Engineer | no by default | PR/read + release evidence | read-only | no | yes | external R1 gate only |

Global invariants:

- `CAN_APPROVE_R2=NO` for every agent.
- No agent may read Kubernetes Secret values.
- No agent may use Kubernetes write verbs for durable repair.
- No implementation agent may merge its own change.
- R1 may be merged only after independent review, QA and required CI gates pass,
  by an external release gate or human authorized by policy.
- R2 always requires the human operator.
- Logical model names are capabilities. Consumers must not name physical LLM
  providers or model IDs.

The current Paperclip V1 uses `opencode_local`. Until runtime connector/tool
policies are qualified for the installed Paperclip version, the matrix above is
partly declarative. GitHub App scopes, Kubernetes RBAC, virtual LiteLLM keys and
network policy are the enforceable boundaries.
