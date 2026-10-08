# Software Factory capability contract

This file defines the intended least-privilege boundary for each Paperclip role.
Prompts are not a security boundary. Runtime credentials, connectors, shell access,
network policy and Kubernetes RBAC must enforce the same matrix.

The broader organization-level desired state lives in
`desired-state/company.yaml`. It is the canonical Git contract for the
mandatory Portfolio Lead, Principal Architect, Agents Orchestrator, Staff
Engineer, QA & Release, Factory/Data Lead, Data Platform Engineer and Agent
Experience Engineer roles. Existing Paperclip agent contracts are reused via
`bootstrapAgentRef`; a null reference models a role without provisioning it.

Before adding a capability, component or service, record a capability lookup
and classify the proposal as `REUSE`, `EXTEND`, `COMPOSE`, `ADAPTER`,
`NEW_COMPONENT`, `NEW_SERVICE` or `BU_CANDIDATE`. New interfaces, dependencies,
services, migrations or security/execution boundaries also require an accepted
ADR. `defaultHeartbeat: OFF` and `CAN_APPROVE_R2=false` are invariants of the
desired state, not prompt-only preferences.

| Role | Git write | GitHub write | Kubernetes | Research tools | Runtime/browser | Merge authority |
|---|---|---|---|---|---|---|
| Engineering Manager | no | no | metadata/read only if required | optional | no | no |
| Researcher | no | no | none | yes | no | no |
| Implementation Engineer | branch/worktree only | branch + PR | read-only | on-demand | limited diagnostics | no self-merge |
| Reviewer | no | review/read only | read-only if evidence requires it | optional | limited | no |
| QA & Release Engineer | no by default | PR/read + release evidence | read-only | no | yes | external R1 gate only |
| Factory Platform Lead | no | no | metadata/read only if required | yes | no | no |
| Data Platform Engineer | branch/worktree only | branch + PR | read-only | on-demand | limited diagnostics | no self-merge |
| Harness Engineer | branch/worktree only | branch + PR | read-only | on-demand | limited diagnostics | no self-merge |

Global invariants:

- `CAN_APPROVE_R2=NO` for every agent.
- No agent may read Kubernetes Secret values.
- No agent may use Kubernetes write verbs for durable repair.
- No implementation agent may merge its own change.
- R1 may be merged only after independent review, QA and required CI gates pass.
- R2 always requires the human operator.
- Logical model names are capabilities; consumers must not name physical providers.
- Factory improvement agents may propose or implement bounded changes but may not self-merge or self-deploy their own control plane.
- Commercial product dependencies require an explicit license/commercial-use check before adoption.
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
