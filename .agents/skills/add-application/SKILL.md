---
name: add-application
description: Add one application using kube-ops standard Kubernetes, identity, storage and durability contracts.
---

# Add application

1. Verify current upstream image/chart and auth capability.
2. Prefer native OIDC with Authentik; otherwise preserve application-native client semantics.
3. Use namespace + upstream Helm/Kustomize/native resources + Gateway API.
4. Use `proxmox-csi` for persistent PVCs.
5. Use CNPG for PostgreSQL; do not deploy an embedded PostgreSQL chart when external DB is supported.
6. Deliver externally-owned/runtime secrets through ESO/Doppler.
7. Add least-privilege network policy matching actual flows.
8. Stateful unique data requires a backup/restore contract.
9. Pin versions in Renovate-friendly form.
10. Render the app and relevant active/staged gates before PR handoff.

Do not introduce a custom application CRD/DSL.
