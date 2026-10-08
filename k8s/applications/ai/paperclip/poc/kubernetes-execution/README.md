# Paperclip Kubernetes execution qualification (non-live)

This directory is a review/render candidate only. It is not referenced by the
production Paperclip Kustomization and must not be enabled by this change.

## Versioned result (2026-10-08)

- npm stable `@paperclipai/plugin-kubernetes` is `2026.1005.0`.
- npm integrity is
  `sha512-JXlPosXgqYxt6B2/J1tQtDnbVK/OiE+tsX0j8V3UgepD8MndIgBE5OP+qkE/xoyHn3PYFb12ZdLr9iprNHgLUg==`.
- The package manifest is plugin id `paperclip.kubernetes-sandbox-provider`,
  plugin version `0.1.0-alpha.1`.
- The package source and built distribution hard-code
  `agents.x-k8s.io/v1alpha1` for `sandbox-cr`.
- The current upstream Agent Sandbox release is `v1.0.5`; its published CRD
  serves `agents.x-k8s.io/v1beta1`. The published `v0.5.6` manifest also
  serves `v1beta1`.

Therefore `sandbox-cr` is **BLOCKED** for this repository until Paperclip
publishes a plugin that speaks the deployed Agent Sandbox API, or a compatible
Agent Sandbox release is identified and pinned. Do not install the current
`agent-sandbox` release and then attempt to run the current plugin: the API
versions do not match.

The stable fallback is `backend: job`. It needs Kubernetes 1.27+ and no Agent
Sandbox CRD/controller, but it is one-shot: it has no multi-command exec and
cannot use the plugin's native file-sync path. It is suitable for a deferred
smoke only after a real runtime image is pinned.

## What is actually GitOps-configurable here

Paperclip Operator `0.19.1` exposes the in-cluster execution contract in
`spec.adapters.execution` and maps it to server environment variables. The
operator also creates the execution ClusterRole/ClusterRoleBinding only when
`mode: kubernetes`. `spec.plugins` pins the package installation, while the
operator's execution block supplies the server-side Kubernetes provider
configuration.

The candidate files deliberately keep this overlay detached from production.
The operator's CRD is the source of truth for field spelling; in particular it
uses `egressAllowFQDNs` and `egressAllowCIDRs`, while the plugin's own JSON
configuration uses `egressAllowFqdns` and `egressAllowCidrs`.

## Upstream primitive qualification

| Primitive | Result | Evidence / constraint |
|---|---|---|
| `sandbox-cr` | BLOCKED | Plugin `2026.1005.0` emits `v1alpha1`; current Agent Sandbox releases serve `v1beta1`. |
| `job` fallback | STATIC-READY | `batch/v1`, `backoffLimit: 0`, `activeDeadlineSeconds: 3600`, TTL default 900s. No exec or native file sync. |
| Codex adapter | STATIC-SUPPORTED / RUNTIME-UNKNOWN | `codex_local` is in the plugin registry and defaults to `ghcr.io/paperclipai/agent-runtime-codex:v1`; upstream issue #8757 reports the `:v1` runtime tags are not published. Pin a verified digest/tag before a run. |
| RBAC | STATIC-DEFINED | Operator grants only the plugin's concrete API calls: namespaces, tenant SAs/Roles/Bindings, quotas, limits, policies, pods/log, pods/exec, Secrets, Jobs; Sandbox CR and Cilium policy are conditional. No wildcard rules. |
| PSS | STATIC-DEFINED | Tenant namespace labels `enforce/audit/warn=restricted`; pod is non-root, RuntimeDefault seccomp, read-only root filesystem, no privilege escalation, drops all capabilities. |
| ResourceQuota | STATIC-DEFINED | Candidate bounds each tenant to 4 pods, 2 CPU/4Gi requests, 4 CPU/8Gi limits. |
| LimitRange | STATIC-DEFINED | Candidate defaults 100m/256Mi requests and 500m/1Gi limits, with 2 CPU/4Gi max. |
| Cilium FQDN egress | STATIC-DEFINED | `egressMode: cilium` creates a deny-all baseline plus Cilium FQDN allow-list; DNS and Paperclip callback remain explicit base rules. |
| Per-run credentials | STATIC-DEFINED | Plugin creates an Opaque Secret containing the bootstrap token and adapter env, owner-referenced to Job/Sandbox. Secret values are never committed or displayed. |
| Cleanup | STATIC-DEFINED, unverified live | Release deletes Job/Sandbox with foreground propagation; destroy also deletes the pod and Secret and treats 404 as success. Tenant resources are first-write-wins and are not automatically garbage-collected. |
| Failure recovery | STATIC-DEFINED | Pending/running leases can resume; terminal or missing pods are not restartable and cause a fresh lease. Job failures do not retry (`backoffLimit: 0`). |
| Resource footprint | STATIC | One tenant namespace + SA + Role/Binding + quota + limit range + deny-all/egress policy; one per-run Job/Sandbox + pod + Secret (+ optional run-scoped policy). Default pod requests 250m/512Mi, limits 2 CPU/4Gi, writable `emptyDir` budget 12Gi. |
| GitOps manageability | PARTIAL | Operator Instance, plugin pin and server execution policy are Git-managed; tenant/run resources are runtime-created by Paperclip and are not Argo desired state. |

## Deferred benchmark gate

The orchestrator may authorize exactly one disposable run only after all of
these are true:

1. A Paperclip plugin build that speaks the installed Agent Sandbox API is
   pinned, or the benchmark explicitly selects `backend: job`.
2. The Codex runtime image is pinned to a verified published tag/digest and
   contains the adapter CLI plus `git`/`tar`/`tini`.
3. The Paperclip image and plugin package are version-compatible; no live
   container patching is allowed.
4. The operator-rendered execution ClusterRole is reviewed and no production
   credentials are in the candidate environment.
5. Cilium policy, DNS, Paperclip callback, LiteLLM callback, and only the
   intended GitHub/API destinations are proven from the disposable tenant.
6. The run proves workspace transfer, branch/commit/PR path, bounded
   resources, cleanup, and recovery. No B3 benchmark may run concurrently.

## Static checks

```sh
helm template paperclip-operator oci://ghcr.io/paperclipinc/charts/paperclip-operator \
  --version 0.19.1 --include-crds >/tmp/paperclip-operator-0.19.1.yaml
kustomize build k8s/applications/ai/paperclip/poc/kubernetes-execution
just check
```

The first command is read-only and validates the installed operator chart
schema. The candidate Kustomization is intentionally not added to Argo.

## Primary upstream references

- https://github.com/paperclipai/paperclip/tree/v2026.1005.0/packages/plugins/sandbox-providers/kubernetes
- https://www.npmjs.com/package/@paperclipai/plugin-kubernetes
- https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.5
- https://github.com/kubernetes-sigs/agent-sandbox/blob/main/docs/api-migration-guide.md
- https://github.com/paperclipinc/paperclip-operator/tree/v0.19.1
- https://github.com/paperclipai/paperclip/issues/8757
