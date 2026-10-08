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
resources, cascade cleanup when a sandbox lease is released, a 15-minute
completed-Job cleanup TTL for the stable fallback, and a one-hour activity
deadline. The supplied OpenCode runtime is pinned by immutable digest through
the declarative `adapters[].runtimeImage` registry entry.

The candidate deliberately has no `imagePullSecrets`, no forwarded `envKeys`,
and no production Secret reference. The plugin-generated tenant ServiceAccount
does not automount a token, and its namespaced Role is limited to reading pod
logs. The Paperclip server still needs its separately qualified in-cluster
control-plane access to create and clean up sandbox resources; the coding
workload has no Kubernetes write authority.

`imageAllowList` contains only the supplied immutable digest. The candidate
uses the adapter registry as the authoritative runtime source and is not a
claim that the live Company or Paperclip environment has been migrated.
