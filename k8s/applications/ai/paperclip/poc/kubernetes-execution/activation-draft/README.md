# Paperclip Kubernetes sandbox activation draft

This directory is an activation package only. It is deliberately not
referenced by `k8s/applications/ai/paperclip/kustomization.yaml` and must not
be applied or merged until every gate below has an observed result.

## Selected chain

The selected target is option A:

```text
Paperclip source containing merged SmadjaPaul/paperclip#11 and #14
  -> bundled local Kubernetes provider (v1beta1 provider fix)
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

## Operator plugin installation boundary

The `stubbi/paperclip-operator` `v0.19.1` source is pinned for this review at
commit `30d762c59185f5b67aec3a2f8bd1ce27b44a5a2e`. Its CRD documents
`spec.plugins`, but the controller's rendered StatefulSet path has no
`spec.Plugins` consumer and performs no npm/pnpm installation from that field.
Consequently the candidate intentionally omits `spec.plugins`: the selected
provider must come from Paperclip's image bundle and its
`SELF_HOSTED_AUTO_INSTALL_KEYS=["kubernetes"]` path. This avoids a second,
unverifiable npm installer and prevents selecting the upstream package that
still documents the alpha contract. The operator field remains available for
other operator features, but it is not evidence that this provider is present.

## Immutable inputs

- Paperclip provider fix: `SmadjaPaul/paperclip#11`, corrected source HEAD
  `15f1c38525715fb8f8070cfa63df1dda3b8bafd4`, merged as
  `c0ee3d95a9f83041bab8f52abf9bf1becbcf3ebf`.
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

1. Paperclip#11 and #14 are merged. Its replacement Paperclip image is not yet published and must pass H3 authorization before publication. Record the exact image index and amd64
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
   get; Pod exec get/create (the WebSocket handshake uses GET); per-run Secret create/delete; and Sandbox
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

## Evidence update — merged PR #14 (2026-10-10)

Paperclip #11 was merged at `c0ee3d95a9f83041bab8f52abf9bf1becbcf3ebf`.
Paperclip [#14](https://github.com/SmadjaPaul/paperclip/pull/14)
was merged at `90e47758119910f8c7ecda1de55fd2b378ca1a28`,
from HEAD `3534bd8264802ada420c8277d4b4740349ec76e6`.

- [Kind CI 38089528661](https://github.com/SmadjaPaul/paperclip/actions/runs/38089528661)
  passed 222 tests in a disposable Kind cluster: v1beta1 Ready generation,
  multi-exec, WebSocket transport, workspace sync, token/network isolation,
  deletion during wait and cleanup with tenant namespace retained.
- [Image CI 38090000606](https://github.com/SmadjaPaul/paperclip/actions/runs/38090000606)
  built the amd64 `cloud` candidate with the Kubernetes plugin and verified
  the bundled manifest/worker/SDK. `push=false`, no image published.
- These tests do NOT prove an actual Paperclip server heartbeat,
  `opencode_local` LLM call, scoped LiteLLM virtual key, GitHub PR creation,
  Operator bridge deployment, or homelab E2E.

### Release blocker: the official fork publication route is not qualified

`SmadjaPaul/paperclip/.github/workflows/fork-ghcr-publish.yml` currently
builds `target: production` without the Kubernetes plugin bundle.
PR #14 qualified `target: cloud` with
`CLOUD_BUNDLED_PLUGINS=kubernetes` and
`CLOUD_BUNDLED_SERVER_DEPS=@sentry/node`.
DO NOT use the production release workflow unmodified to satisfy this gate.
Prepare a reviewed manual publish path which pins the merged source SHA,
uses the tested bundle target, verifies the plugin in the **pushed** image,
records the immutable image index / amd64 digest, provenance, attestations,
and does nothing until H3's publication approval.

### Pre-activation network/identity blockers

- Current `paperclip/networkpolicy.yaml` does not explicitly allow Paperclip
  control-plane egress to the Kubernetes API, nor tenant-Sandbox callback
  ingress to the Paperclip server. Verify the exact Cilium identities and
  restricted ports offline before any change to the active graph.
- `PAPERCLIP_ADAPTERS` in the non-live `instance-candidate.yaml` has
  `envKeys: []`. Upstream `buildAdapterEnv()` copies only declared envKeys
  from the server process. The existing ESO key
  `APP_PAPERCLIP_LITELLM_API_KEY` is only a server-side mapping; its status
  as a scoped virtual key, permitted models/budget, and injection into the
  per-run Secret are **NOT PROVEN**. Never forward a LiteLLM master key.
- Explicitly require `get` and `create` on `pods/exec`; #14 proved that
  direct kubectl exec can pass with create alone while the plugin WebSocket GET
  handshake fails with 403.
- Render the exact Operator Instance CRD and observe plugin startup on the
  candidate **before** any deployment. The source candidate and the active
  Operator bridge are different contracts; Kind did not exercise the bridge.

Keep `H3_AGENT_IMAGE_EXTERNAL_OWNER=false`, image-publication approval
blocked, `orchestratorApproval=false`, SMA-31 unexecuted and #400
**draft/outside Argo's active resource graph**.

### Existing-tenant label and callback preflight

`packages/plugins/sandbox-providers/kubernetes/src/cilium-network-policy.ts`
uses `app: paperclip-server` to select callback port 3100, while the
active `kube-ops/paperclip/networkpolicy.yaml` selects the server through
`app.kubernetes.io/name: paperclip` and
`app.kubernetes.io/component: server`. Both selectors might coexist
on the deployed Pod, but no live label evidence has been collected.
Do **not** assume a match; require a read-only Pod-label inspection and
a bounded callback reachability probe before enabling tenant traffic.

`tenant-orchestrator.ts` uses first-write-wins provisioning for tenant
namespaces, quota, LimitRange and policies. For every pre-existing tenant,
compare namespace ownership labels and object fingerprints against the
current desired policy. A missing/mismatched object is an activation
blocker, never a reason to silently mutate an existing namespace.
