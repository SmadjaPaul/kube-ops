# OpenConnector staging (inactive)

This directory is not referenced by the parent Argo CD Kustomization.
The deployment remains at 0 replicas until image digest, encrypted credentials,
network egress boundaries and OAuth multi-user isolation have been validated.

Use the upstream OpenConnector image and an encrypted store. For the first
acceptance run, use a single, explicitly restricted persistent runtime token
and only read-only Home Assistant/Paperless actions. Do not use its admin token
or unrestricted bootstrap runtime token in Mastra. The Personal Agent's MCP
integration is developer-only until Authentik identity checks are implemented.

Provision Doppler keys and Cilium policy before any promotion. No external
Google OAuth, public ingress or Composio is needed for the first homelab test.
