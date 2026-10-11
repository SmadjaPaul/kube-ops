# Agent Sandbox controller

This is the GitOps installation boundary for the upstream Agent Sandbox
controller. It is intentionally limited to the v1.0.5 base release asset:
the extension CRDs and extension RBAC are not needed by the Paperclip
v1beta1 provider.

- upstream asset: `sandbox.yaml`
- release: `v1.0.5`
- asset SHA-256:
  `e89fd95c0aa57609fa24be4112bd52ce67fe8939ecf6f3c17edf2f1e8f1eb860`
- controller image, Linux amd64:
  `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:dd92effc491e593aea41e19169683a09e1d1193d43f25204ba9fe1fbbc53ff8f`
- source tag commit:
  `82d410efd5a279e887cdcf8c01e742a345fef63d`

The upstream ClusterRole is retained because it is the controller's
reconciler contract. Paperclip's server identity is not granted these
controller permissions by this package. The Sandbox CRD serves and stores
`agents.x-k8s.io/v1beta1` only.

This controller is infrastructure only. It does not activate Paperclip's
instance-global Kubernetes execution mode, create a tenant, create a
Sandbox, or grant Paperclip control-plane RBAC.
