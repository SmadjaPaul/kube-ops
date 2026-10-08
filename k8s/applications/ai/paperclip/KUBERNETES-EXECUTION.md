# Paperclip Kubernetes execution qualification

## Decision

Keep the Paperclip Operator as the deployment mechanism for the Paperclip
server. Do not replace it with hand-written Deployment/Job resources.

The production execution target for autonomous agents is Paperclip's first-party
Kubernetes sandbox provider, not `opencode_local`.

The installed operator API already exposes the required execution contract via
`spec.plugins` and `spec.adapters.execution`, including:

- `mode: kubernetes`;
- `backend: job|sandbox-cr`;
- Cilium-aware egress policy;
- per-tenant namespace prefix;
- per-tenant ResourceQuota;
- per-tenant LimitRange.

This means no custom controller is required.

## Current vs target

Current bootstrap path:

```text
Paperclip server
  -> opencode_local
  -> agent process in the Paperclip runtime boundary
```

Target path:

```text
Paperclip server
  -> @paperclipai/plugin-kubernetes
  -> Kubernetes sandbox backend
  -> isolated agent workload
```

The server deployment and the agent execution placement are separate concerns.

## Why the migration is staged

The first harmless DOC smoke remains on the local adapter so that it tests the
Company/DAG/review workflow without simultaneously changing execution
infrastructure.

After that, a disposable sandbox POC qualifies the Kubernetes execution path.
Only then are roles migrated progressively.

## Upstream-risk policy

The Kubernetes sandbox surface is still moving quickly. Treat missing runtime
images, plugin/runtime version skew, sandbox CR incompatibility or missing
adapter binaries as upstream blockers.

Forbidden workaround: patching plugin distribution files or runtime images
inside a live Paperclip pod.

Allowed R1 work:

- pin and render upstream-supported versions;
- prepare non-live Kustomize candidates;
- add static tests and documentation;
- open causal PRs for reproducible upstream defects.

R2 is required only when the action crosses an existing sensitive boundary
(credentials, destructive cleanup, irreversible/disruptive state mutation).

## H3 HUMAN_GATE — agent image ownership

The requested agent image qualification is blocked at the Git ownership
boundary, not by a missing Kubernetes field:

- `kube-ops` contains no Dockerfile or build context for
  `ghcr.io/smadjapaul/paperclip` or an agent runtime image. Its image workflow
  only builds directories under `images/`.
- The live Paperclip server image is pinned by digest in `instance.yaml`; the
  observed image has `git`, `gh`, `node`, `npm` and `jq`, but lacks `just`,
  `kustomize`, `yq` and `ruby`.
- The installed Operator CRD exposes `spec.adapters.cloudSandbox.defaultImage`
  (defaulting to the external `ghcr.io/paperclipinc/agent-multi:latest`) only
  for the older `cloudSandbox` surface. The first-party
  `spec.adapters.execution.kubernetes` surface has no agent-image field.
- Production currently uses `opencode_local`; the Kubernetes execution file is
  a non-live candidate and must not be activated by this change.

The smallest supported next step is a separately owned, immutable agent image
that passes the required tool probe. A human owner must provide its source,
published digest, architecture support and probe evidence. Only then may a
separate activation change set the supported image field for the chosen
execution surface (or update the upstream plugin contract if the Kubernetes
backend remains the target). Do not install tools into a live Paperclip pod,
retag an unqualified external image, or claim qualification from the server
image alone.

Gate identifier: `HUMAN_GATE=H3_AGENT_IMAGE_EXTERNAL_OWNER`.

## POC acceptance

Before activation, refresh the Paperclip server version, operator version,
plugin version and agent-sandbox API/controller version.

The first POC must prove all of the following:

1. one disposable run creates the expected isolated workload;
2. no production credential is mounted;
3. no Kubernetes write authority is available to the coding workload;
4. required callback/model connectivity works only when explicitly allowed;
5. unrelated private/internet egress is denied;
6. namespace/workload CPU, memory and pod counts are bounded;
7. workspace lifecycle is understood;
8. cleanup completes deterministically;
9. Paperclip server remains healthy;
10. no existing Company agent is silently migrated.

## Candidate overlay

`poc/kubernetes-execution/` is intentionally excluded from the production
Kustomization.

It is a review/render candidate only. Its version pins must be refreshed before
any activation. Do not add it to the production resource graph as part of a
documentation/backlog/bootstrap change.
