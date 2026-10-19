# Mastra Factory isolated agent-sandbox (qualified staging path)

The parent platform kustomization references this directory and Argo currently
reconciles its Namespace, RBAC, Cilium policy, `SandboxTemplate` and
`SandboxWarmPool`. This is still not a production recovery qualification:
Factory has one replica, the warm pool has zero idle replicas, and no claim
should be assumed to exist until the controller creates one.

Target API: Kubernetes SIG Apps Agent Sandbox v1.0.6 (the CRDs/controller must
be installed and qualified separately).
Factory should use `FACTORY_SANDBOX_PROVIDER=kubernetes`,
`FACTORY_KUBERNETES_NAMESPACE=mastra-sandbox`,
`FACTORY_KUBERNETES_WARMPOOL=mastra-code`, root `/workspace`.

The upstream `SandboxWarmPool.spec.replicas=0` is supported: claims cold-start
without permanent idle Pods. It does not itself prove that the controller is
installed, that gVisor is working, or that a claim/PVC can be recreated
without losing unpushed work.

## Durable state and backup policy

The workspace PVC is created dynamically by `SandboxClaim`; it is not a
StatefulSet `volumeClaimTemplates` object. Longhorn can select a PVC for a
RecurringJob when the official source labels are present, but a permanent
daily policy would leave remote backups behind when a short-lived workspace
expires. There is no owner-aware retention or cleanup controller in this
repository, so dynamic workspaces remain **one-off protected only** until the
Factory can prove that the useful state is pushed to the expected Git branch
and no unpersisted artifact remains. The current audit therefore keeps these
workspaces out of `EPHEMERAL_VERIFIED` and does not add a recurring policy that
would accumulate orphaned S3 backups.

Autonomous claim recreation is fail-closed. The Factory contract accepts a
trusted durable-state reader only when it proves repository/branch identity, a
remote commit SHA, a clean workspace and an empty unpersisted-artifact
inventory. A missing or unavailable proof must refuse recreation.

Outstanding release gates:
- confirm Talos node really supports the gVisor RuntimeClass; never silently
  fall back to runc for untrusted source code;
- use the published immutable `ghcr.io/smadjapaul/mastra-sandboxd` digest
  (`sha256:22906dc31b9ef7d2a46f6eff816b380301311bce5eacdc56df2b7eb8140614c0`)
  containing git, Node 22, and npm;
- verify Agent Sandbox CRDs and v1beta1 compatibility, Cilium endpoint labels,
  sandboxd root relative filesystem, in-cluster-service DNS and pod network;
- verify ServiceAccount privileges scoped to this namespace, without cluster-admin;
- add Factory-only egress to Kubernetes API and sandboxd REST/gRPC;
- load one test repository, inject one ephemeral LiteLLM key through per-process
  env, create PR, kill session, revoke key and delete SandboxClaim/PVC;
- validate suspend/resume, expiry, duplicate claims and idempotent cleanup.

Network egress from untrusted sandboxes is explicitly denied until deliberate
FQDN/endpoint policy is reviewed. This will block git clone and npm install
during first runs; do not loosen network policy globally.
