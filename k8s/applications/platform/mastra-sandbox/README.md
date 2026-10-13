# Mastra Factory isolated agent-sandbox (staging only)

This directory is NOT referenced by Argo, and Factory replicas remain zero.
Target API: Kubernetes SIG Apps Agent Sandbox v1.0.6 (CRDs must be installed separately).
Factory should use `FACTORY_SANDBOX_PROVIDER=kubernetes`,
`FACTORY_KUBERNETES_NAMESPACE=mastra-sandbox`,
`FACTORY_KUBERNETES_WARMPOOL=mastra-code`, root `/workspace`.

The upstream `SandboxWarmPool.spec.replicas=0` is supported: claims cold-start
without permanent idle Pods. This does not mean the controller is installed.

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
