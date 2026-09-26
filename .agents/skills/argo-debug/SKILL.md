---
name: argo-debug
description: Diagnose Argo CD reconciliation and application health without mutating the cluster.
---

# Argo debug

Evidence order:

1. Git desired state and expected revision.
2. Argo Application sync/health/reconciled revision.
3. Argo managed-resource tree, events and workload logs.
4. Kubernetes read-only evidence only when Argo cannot answer the question.

Prefer the in-cluster Argo MCP in read-only mode. Never call sync/resource-action tools, even if a client exposes them. Fix desired state through Git and verify the merged revision becomes Synced/Healthy.
