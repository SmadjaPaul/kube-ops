---
name: repo-navigation
description: Navigate kube-ops with progressive disclosure. Use before broad repository search or when ownership/path is unclear.
---

# Repository navigation

1. Read root `AGENTS.md`.
2. Run `just inventory`; do not start with recursive tree/grep.
3. Classify ownership: Kubernetes/Argo stays here; Proxmox/Talos machine lifecycle/UniFi/Cloudflare/Doppler authority belongs to `homelab-infra`.
4. For an app, read only its directory plus the narrow platform primitive it consumes.
5. For runtime work use `runtime-observer`; for sync state use `argocd-debug`.
6. Preserve findings in tests/skills/runbooks only if future agents need them.
