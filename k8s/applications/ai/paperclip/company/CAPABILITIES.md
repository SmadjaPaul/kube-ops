# Software Factory capability contract

This file defines the intended least-privilege boundary for each Paperclip role.
Prompts are not a security boundary. Runtime credentials, connectors, shell access,
network policy and Kubernetes RBAC must enforce the same matrix.

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
- R1 may be merged only after independent review, QA and required CI gates pass.
- R2 always requires the human operator.
- Logical model names are capabilities; consumers must not name physical providers.
- Coding sandboxes should not receive a Kubernetes ServiceAccount token by default.
- Runtime egress should be allow-listed rather than ambient.

## Runtime enforcement

The bootstrap Company currently uses `opencode_local`. That is sufficient for
the first harmless documentation smoke, but it does not provide the final
process-isolation boundary for autonomous production work.

The production target is the first-party Paperclip Kubernetes execution path:

`Paperclip -> @paperclipai/plugin-kubernetes -> isolated sandbox workload`

The installed Paperclip Operator API already exposes `spec.plugins` and
`spec.adapters.execution`, including per-tenant resource quotas and Cilium-aware
egress policy. Do not build a parallel custom Job controller.

Kubernetes sandbox execution is qualified only after one disposable agent proves:

- isolated execution namespace/workload;
- expected workspace lifecycle;
- only required GitHub/Paperclip/LiteLLM connectivity;
- unrelated egress denied;
- no sensitive production secret present in the sandbox;
- no Kubernetes write authority for the coding role;
- bounded CPU/memory/pod quota;
- deterministic cleanup;
- no regression of the existing Paperclip control plane.

Until then, the matrix is a mix of enforced external boundaries and declarative
intent. The migration must reduce that gap rather than add prompt-only policy.
