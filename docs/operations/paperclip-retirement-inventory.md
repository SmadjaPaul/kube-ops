# Paperclip retirement inventory

Status: **cleanup contract only; live deletion deferred**.

The retirement PR and this contract must not be treated as permission to prune
live objects. Argo CD uses automated pruning, so live ownership must be
inventoried before any generator, allow-list or policy reference is removed.

## Independent cleanup contract

- CI no longer calls Paperclip-only harnesses and preflight scripts that are
  not part of the retained repository contract.
- The Paperclip retirement PR remains responsible for deleting its Git-owned
  manifests in a separate review.
- This document records the live checks required before narrowing Argo scope.

## References requiring live inventory

| Surface | Git reference | Required evidence before removal |
| --- | --- | --- |
| ApplicationSet | `k8s/applications/ai-paperclip-h3` generator path | Argo Application plus desired objects, PVC/PV/CNPG/backup ownership |
| Applications AppProject | `paperclip`, `paperclip-exec-h3` destinations | No active Application targets either namespace |
| Infrastructure AppProject | `paperclip`, `paperclip-operator-system` destinations | No operator or custom-resource ownership remains |
| Controllers AppProject | Paperclip OCI source and operator namespace | No live Application uses the source or destination |
| VPA | Paperclip target in `vpa/recommendations.yaml` | VPA and target ownership confirmed |
| RBAC | Retired Paperclip Role/Binding manifests | Live Role, RoleBinding, ClusterRole and ClusterRoleBinding inventory |
| NetworkPolicy | Executor/blackbox Paperclip selectors | No active endpoint needs the cross-namespace rule |
| Monitoring | Paperclip probes and alerts | Endpoint retirement and alert ownership confirmed |

The follow-up retirement PR must state the expected prune set. It remains
blocked if any PVC, PV, database, backup or operator-owned resource is
ambiguous. No delete, prune or Argo mutation is performed by this contract.
