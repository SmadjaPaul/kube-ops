# Agent Sandbox controller

This is the GitOps installation boundary for the upstream Agent Sandbox
controller. It migrates the existing installation atomically to v1.0.6 so
the extension CRDs required by Mastra's `SandboxTemplate` and
`SandboxWarmPool` are served by the same controller. It does not install a
second controller.

- upstream asset: `sandbox-with-extensions.yaml`
- release: `v1.0.6`
- asset SHA-256:
  `e6fa909d82392b201ef80003dd91390450266ba356caa9be04a1c89c3caa65dc`
- controller image, Linux amd64:
  `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:876f9621e0f0e168bcff13aa377880b75fd37e1c8712f2f249e8878c22d06ffd`
- controller image index:
  `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:14c479c9e89ca87d05dfcf597840473c0196d6e6eec622a7959e72108d75b24e`
- source tag commit:
  `cd0761d5001baaf293460cd382ee318744d6b249`

The upstream ClusterRole is retained because it is the controller's
reconciler contract. Paperclip's server identity is not granted these
controller permissions by this package. The release serves and stores
`agents.x-k8s.io/v1beta1` plus the extension API needed by the staged Mastra
resources.

This controller is infrastructure only. It does not activate Paperclip's
instance-global Kubernetes execution mode, create a tenant, create a
Sandbox, or grant Paperclip control-plane RBAC.
