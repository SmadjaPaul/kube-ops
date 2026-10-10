# Paperclip Kubernetes sandbox activation draft

This directory is an activation package only. It is deliberately not
referenced by `k8s/applications/ai/paperclip/kustomization.yaml` and must not
be applied or merged until every gate below has an observed result.

## Selected chain

The selected target is option A:

```text
Paperclip image built after SmadjaPaul/paperclip#11
  -> @paperclipai/plugin-kubernetes 0.1.0 (v1beta1 provider fix)
  -> Agent Sandbox v1.0.5
  -> agents.x-k8s.io/v1beta1 Sandbox
  -> ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d
```

The provider correction is contract-compatible with the installed Paperclip
Operator: the Operator still owns `paperclip.inc/v1alpha1 Instance`, while the
provider changes only its internal Sandbox API version, status conditions and
owner-reference metadata. The current deployed Paperclip image cannot satisfy
this chain: it is pinned to `sha256:aa46b347...` from commit `64ae540d`, before
Paperclip#11, and the standard production Docker target does not build the
Kubernetes plugin distribution.

## Immutable inputs

- Paperclip provider fix: `SmadjaPaul/paperclip#11`, corrected HEAD
  `8feb337652d905c5253b96bf3304571e802863a4`; it is open and unmerged.
- Agent Sandbox release asset:
  `https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.5/sandbox-with-extensions.yaml`
  SHA-256 `b150cb058c577c59c42b060ff7f22e31b5311ca80430db98129f1280a0e85970`.
- Agent Sandbox controller, Linux amd64:
  `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:dd92effc491e593aea41e19169683a09e1d1193d43f25204ba9fe1fbbc53ff8f`.
- Agent image, Linux amd64:
  `ghcr.io/paperclipai/agent-runtime-opencode@sha256:349fc68e609998f1d9fc77f94208d50263368b49631f746a51f819917d9b0d2d`.

The image digest must be observed in the created disposable Sandbox pod before
H3 can be marked passed. No digest or tag may be substituted during review.

## Gates before merge

1. Paperclip#11 is merged after independent review and its replacement
   Paperclip image is published. Record the exact image index and amd64
   manifest digests; do not use the currently deployed image.
2. The plugin is loadable from that exact image. Prove the bundled `dist/`
   entrypoints and manifest version, then observe Paperclip reporting the
   Kubernetes provider as loaded. Source presence in Git is insufficient.
3. Render this overlay against the installed Operator CRD. Confirm the
   `Instance` bridge accepts only its Operator fields (`egressAllowFQDNs`,
   quota and LimitRange); provider-only fields must remain in the translated
   runtime configuration.
4. A human approves the external-owner H3 gate and the orchestrator approves
   one bounded SMA-31 run. Until then, do not install Agent Sandbox, grant
   RBAC, or call an LLM.
5. Grant only the Paperclip server identity the reviewed control-plane
   permissions: namespace get/create; tenant ServiceAccount, Role and
   RoleBinding get/create; ResourceQuota and LimitRange get/create;
   NetworkPolicy and CiliumNetworkPolicy get/create; Pod get/list; Pod logs
   get; Pod exec create; per-run Secret create/delete; and Sandbox
   get/create/delete. Namespace creation is the only cluster-scoped write;
   namespace deletion is never part of run cleanup.
6. Verify the agent pod has `automountServiceAccountToken: false`, runs as
   UID/GID 1000, drops all capabilities, uses RuntimeDefault seccomp and has
   only the reviewed Cilium FQDN allow-list.
7. Use one synthetic, non-production credential and one disposable workspace.
   Observe image digest, callback, bounded execution, cleanup and telemetry
   outcome. Do not migrate Company agents.

## Persistent tenant namespaces and cleanup

The tenant namespace is persistent per Company and is created or reused by the
tenant provisioning path. It is not an ephemeral per-run resource. Terminating
a run must delete only the run-scoped Sandbox, its pod, its per-run Secret and
any temporary run policy. The namespace, its quota, LimitRange and baseline
egress policy remain. Deliberate tenant teardown is a separate, explicitly
approved operation with an ownership check.

Before activation, run a read-only drift check for every existing tenant
namespace known to the Paperclip Company registry. Compare the desired
ResourceQuota, LimitRange and CiliumNetworkPolicy fingerprints with the
candidate contract; a missing or changed object is a blocker, not an
auto-repair. The check must cover existing namespaces, not only a freshly
provisioned tenant.

## Rollback

Before any workload exists, rollback is a Git revert of this activation PR and
Argo convergence. During the disposable run, release the single lease and
confirm the Sandbox, pod, Secret and temporary run policies are cleaned up
while the tenant namespace remains. If the image or provider fails, restore
the previous Paperclip image digest and leave
the production `opencode_local` path unchanged. Do not delete Paperclip PVCs,
mutate production Secrets or use a live pod as a repair surface.

## Why option B is not selected

The selected plugin build targets `agents.x-k8s.io/v1beta1` directly.
Agent Sandbox v0.5.6 is not selected because it would require a separate
alpha provider contract. Option B is therefore rejected for this activation;
it is not an implicit fallback and must not be enabled by this PR.
