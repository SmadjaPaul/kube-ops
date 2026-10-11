# Non-live Kubernetes execution candidate

This directory is intentionally not part of the production Paperclip
Kustomization.

It exists to keep the first-party operator configuration reviewable before a
sandbox POC. Rendering it is R0/R1. Adding it to the production reconciliation
graph is a separate change and must follow the qualification gates in
`../../KUBERNETES-EXECUTION.md`.

The static compatibility candidate pins Agent Sandbox `v1.0.5`, whose release
manifest serves the single selected API `agents.x-k8s.io/v1beta1`. Paperclip#11
uses that contract directly; v0.5.6 is not selected because it would require a
separate alpha provider contract. This is a static compatibility finding, not a
live H3 pass.

Before any activation:

- refresh the Paperclip server/operator/plugin pins;
- verify the pinned Agent Sandbox release asset and controller image digest;
- verify the selected runtime image actually exists and contains the adapter;
- verify the Operator-to-provider bridge: the installed Instance CRD uses its
  own `egressAllowFQDNs`, quota and LimitRange fields, while the upstream
  provider environment schema uses `inCluster`, `adapterType` and
  `egressAllowFqdns`; these provider-side fields must not be copied directly
  into this CRD candidate;
- resolve an immutable runtime image through the supported environment adapter
  registry: `PAPERCLIP_ADAPTERS` carries the exact `runtimeImage` digest into
  the Kubernetes environment configuration. The provider default for
  `opencode_local` remains tag-based, and `imageAllowList` alone is not an
  override because the acquire path passes `imageOverride: null`; the digest
  path is therefore static-code proven here but still requires a live
  disposable-pod observation;
- render against the installed Paperclip Operator CRD;
- confirm heartbeats remain disabled;
- ensure no normal Company work is running;
- use one disposable agent/run;
- do not inject production credentials.

The candidate uses `sandbox-cr`, Cilium allow-list egress, explicit per-tenant
quota/LimitRange bounds and the operator bridge schema. The plugin package and
upstream image evidence are recorded in `version-lock.yaml`; the complete H3
record is in `docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml`.

`PAPERCLIP_K8S_INTERNAL_SERVICES.port` is the Cilium post-DNAT backend port,
not necessarily the Kubernetes Service frontend port: the non-live candidate
declares LiteLLM as `litellm:4000`, while OpenCode connects to the Service on
`80`. The disposable Kind proof must verify that mapping and independently
deny an unrelated Service using the same backend port.

The Paperclip server itself needs a separately reviewed, narrowly scoped
control-plane Role/ClusterRole for tenant provisioning and Sandbox lifecycle:
namespace, tenant ServiceAccount/Role/RoleBinding, quota, LimitRange,
NetworkPolicy, CiliumNetworkPolicy, per-run Secret, Sandbox CR, pod
listing/logs and `pods/exec`. The live `paperclip/paperclip` service account
currently has `no` for every listed verb. The agent pod has no Kubernetes
ServiceAccount token; these are deliberately separate identities.

The image record identifies the upstream owner, immutable platform-specific
digest, source commit, keyless signature identity, non-root execution identity,
probes, resources, egress policy, secret deny-list and rollback. The image
probe and disposable runtime probes remain unexecuted until the human H3 gate
is approved.

The candidate deliberately has no `imagePullSecrets` or production Secret
reference. The image selection belongs to the Paperclip environment/plugin
configuration, not to the Operator `Instance` CRD; the operator candidate must
not be mistaken for a completed Paperclip environment configuration. The
upstream `sandbox-cr` builder sets `automountServiceAccountToken: false` for
the agent pod. The Paperclip server still needs separately qualified in-cluster
control-plane access to create and clean up sandbox resources; the coding
workload must have no Kubernetes API authority.

This remains a review/render candidate. It is not evidence that the live
Company or Paperclip environment has been migrated.
