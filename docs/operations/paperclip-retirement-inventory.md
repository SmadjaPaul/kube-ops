# Paperclip retirement inventory

Status: **Git retirement staged; live deletion deferred**.

This inventory is deliberately separate from the deleted Paperclip manifests.
The Argo CD applications use automated pruning, so removing a generator entry
or narrowing an AppProject without first identifying live ownership could delete
resources or leave them unmanaged. This PR does not authorize or perform that
live operation.

## Deleted from Git in this PR

- Paperclip application, operator, database, ExternalSecret, backups and
  execution-candidate manifests under `k8s/applications/ai/paperclip*`.
- Paperclip-only static scripts and test harnesses.
- CI calls to those deleted Paperclip harnesses and preflight scripts.

## Remaining references to classify before any live prune

| Surface | Reference | Current meaning | Required live proof |
| --- | --- | --- | --- |
| ApplicationSet | `k8s/bootstrap/argocd-root/applications-applicationset.yaml`: `k8s/applications/ai-paperclip-h3` | Generator path with `prune: true` | Argo Application, desired objects, PVC/PV/CNPG/backup ownership |
| Applications AppProject | `paperclip`, `paperclip-exec-h3` destinations | Namespace allow-list | Confirm no active Application still targets either namespace |
| Infrastructure AppProject | `paperclip`, `paperclip-operator-system` destinations | Namespace allow-list | Confirm operator and CR ownership before narrowing |
| AI AppProject | `paperclip` destination | Namespace allow-list | Confirm no remaining AI Application uses it |
| Controllers AppProject | Paperclip OCI source and operator namespace | Source/destination allow-list | Confirm no live Application uses the source or namespace |
| VPA | `k8s/infrastructure/controllers/vpa/recommendations.yaml` | VPA targeting Paperclip CR | Confirm VPA object and target no longer exist or are intentionally retained |
| RBAC | Deleted Paperclip role/binding manifests | Git-owned Paperclip RBAC was removed | Inventory live Role, RoleBinding, ClusterRole and ClusterRoleBinding before deletion |
| NetworkPolicy | Executor ingress and blackbox egress selectors for Paperclip | Cross-namespace policy references | Confirm no active Paperclip endpoint needs the rule |
| Probes/alerts | Blackbox Paperclip URLs and alert rules | Monitoring references | Retire probes/alerts separately after endpoint ownership is confirmed |

## Decision boundary

The remaining references are not proof that Paperclip is still running, and
their absence from Git is not proof that live resources are safe to delete.
The next change must be a read-only Argo/Kubernetes inventory. Only after that
inventory is reviewed may a separate PR remove allow-list entries, generator
paths, VPA/policy references or monitoring probes. That PR must explicitly
state its expected prune set and remain blocked if any PVC, PV, database or
backup ownership is ambiguous.
