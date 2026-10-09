# Non-live Kubernetes execution candidate

This directory is intentionally not part of the production Paperclip
Kustomization.

It exists to keep the first-party operator configuration reviewable before a
sandbox POC. Rendering it is R0/R1. Adding it to the production reconciliation
graph is a separate change and must follow the qualification gates in
`../../KUBERNETES-EXECUTION.md`.

Before any activation:

- refresh the Paperclip server/operator/plugin pins;
- confirm the agent-sandbox CRD/controller version and API compatibility;
- verify the selected runtime image actually exists and contains the adapter;
- render against the installed Paperclip Operator CRD;
- confirm heartbeats remain disabled;
- ensure no normal Company work is running;
- use one disposable agent/run;
- do not inject production credentials.

The candidate uses `sandbox-cr`, Cilium allow-list egress, bounded container
resources and a one-hour activity deadline. The plugin package and upstream
runtime image are pinned in `version-lock.yaml` and the complete H3 record is
in `docs/factory/H3_AGENT_IMAGE_MANIFEST_2026-10-09.yaml`.

The image record identifies the upstream owner, immutable platform-specific
digest, source commit, keyless signature identity, non-root execution identity,
probes, resources, egress policy, secret deny-list and rollback. The image
probe and disposable runtime probes remain unexecuted until the human H3 gate
is approved.

The candidate deliberately has no `imagePullSecrets` or production Secret
reference. The image selection belongs to the Paperclip environment/plugin
configuration, not to the Operator `Instance` CRD; placing plugin-only fields
such as `adapters[]` in the CRD would be rejected by the installed Operator.
The plugin-generated tenant ServiceAccount does not automount a token, and its
namespaced Role is limited to reading pod logs. The Paperclip server still
needs separately qualified in-cluster control-plane access to create and clean
up sandbox resources; the coding workload has no Kubernetes write authority.

This remains a review/render candidate. It is not evidence that the live
Company or Paperclip environment has been migrated.
