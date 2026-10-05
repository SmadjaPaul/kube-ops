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

The current candidate uses `sandbox-cr`, Cilium allow-list egress and bounded
per-tenant quotas. It is not a claim that the current upstream sandbox/runtime
image set is production-ready.
