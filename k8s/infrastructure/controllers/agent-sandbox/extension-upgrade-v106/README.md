# Agent Sandbox v1.0.6 with extensions — staged replacement

The current live GitOps package is **v1.0.5 base only**, intentionally
without SandboxTemplate/SandboxWarmPool extension CRDs and controllers.

This directory is NOT referenced by the parent and MUST NOT be installed
side-by-side with that package. When ready, REPLACE the existing
`k8s/infrastructure/controllers/agent-sandbox` resource declaration
atomically through GitOps after impact review with Paperclip.

Upstream published release (2026-10-08):
- asset `sandbox-with-extensions.yaml`;
- SHA-256 `e6fa909d82392b201ef80003dd91390450266ba356caa9be04a1c89c3caa65dc`;
- version `v1.0.6` (includes extension CRDs/manager).
- optional extensions-only asset SHA256
  `548092ccd782cad4b18e638cb6540c5b2dd46e50365234a8a1f757bf3d5d6335`
  exists, but do NOT mix this with an unvalidated v1.0.5 base controller.

Before migration: confirm controller image digests; test CRD/storage
compatibility, Paperclip Sandbox operations, extension controller startup,
RBAC and conversion, downgrade strategy, and re-verify `kubectl api-resources`.
No auto-promotion and no live cluster access is claimed.
