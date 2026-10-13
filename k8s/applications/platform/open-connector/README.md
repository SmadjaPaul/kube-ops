# OpenConnector staging (inactive)

This directory is not referenced by the parent Argo CD Kustomization.
The deployment remains at 0 replicas until Doppler credentials, encrypted
storage, network egress boundaries and OAuth multi-user isolation have been
validated. There is no Gateway or HTTPRoute.

Use the upstream OpenConnector image and an encrypted store. For the first
acceptance run, use a single, explicitly restricted persistent runtime token
and only the read-only Paperless actions as the first live smoke. Home Assistant
is present in the action allowlist but its network destination remains denied. Do not use its admin token
or unrestricted bootstrap runtime token in Mastra. The Personal Agent's MCP
integration is developer-only until Authentik identity checks are implemented.

Provision Doppler keys and Cilium policy before any promotion. No external
Google OAuth, public ingress or Composio is needed for the first homelab test.

Upstream release pinned for staging: v1.8.0 (published 2026-09-30).
Paperless-ngx actions `list_documents` and `get_document` are present in this release.
The amd64 image is pinned to `sha256:2f1a48c833b2768e6dfa14859ca94b5150da4dbbb9cf6908c404b7f7ee63c302`.

The runtime allowlist exposes only `paperless_ngx.list_documents` and
`paperless_ngx.get_document`. The Cilium policy permits outbound TCP only to the `paperless` workload in
namespace `paperless` (ports 80/8000) and to cluster DNS. The runtime's
`ALLOW_PRIVATE_NETWORK=true` switch does **not** authorize general LAN egress.
Run E2E deny tests for alternate IPs, private services, write methods and
multiple user connections before giving access to other family members.
