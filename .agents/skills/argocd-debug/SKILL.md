---
name: argocd-debug
description: Diagnose Argo CD sync, comparison, health and ApplicationSet failures before descending to Kubernetes.
---

# Argo CD debugging

Evidence order: Git revision -> ApplicationSet -> Application sync/health/conditions -> first failing resource -> Kubernetes.
Use `just status-app <app>` then `just diagnose-app <app>`.
Do not use sync/reconcile as a deployment mechanism; stuck syncs use `scripts/argo-terminate-stuck-sync.sh` per AGENTS.md Safety. Distinguish cosmetic resource health from a real unhealthy workload.
