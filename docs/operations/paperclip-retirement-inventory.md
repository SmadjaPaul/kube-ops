# Paperclip retirement — staged Git cleanup

Status (2026-10-17): **stage 1 runtime prune completed; stage 2 stateless cleanup
and operator GitOps retirement prepared**.

PR #517 removed the Paperclip `Instance` from desired state and Argo pruned the
server workload. This change removes the now-unconsumed application runtime
ConfigMap, admin bootstrap ExternalSecret and application runtime ExternalSecret
from the desired state. It does not remove the operator, database, backups,
namespace, network policies or CNPG credentials.

The existing #494 draft is reconciled onto current `main` without deleting
Kubernetes resources. Deletions only affect the obsolete Paperclip company
package, out-of-tree execution proof-of-concept, Paperclip-specific local CLI
preflights/tests and their harness references. Git history retains every file.

## Runtime explicitly retained for the next retirement gates

- `apps-ai` renders the Paperclip CNPG Cluster, ScheduledBackup, ObjectStore,
  namespace and NetworkPolicy. The Instance and application runtime secrets/config
  were removed in separate reviewed stages. The SQL/WAL/PVC resources are not
  pruned by this change.
- `apps-ai-paperclip-h3` remains present in the ApplicationSet and its
  corresponding directory/Kustomization remains intact. Do not delete a
  generated Application with `prune: true` without a live inventory.
- The operator Application, leader-election RBAC, operator AppProject source and
  Paperclip-specific VPA target are removed by the operator-retirement change.
  The chart-generated CRDs are intentionally retained for a separate explicit
  deletion gate because the live chart marks them `helm.sh/resource-policy:
  keep`; no CR instances remain.
- `velero-daily-paperclip` remains in the controller schedule root until its
  backup retention and content ownership are qualified.
- Docusaurus `website/` and `netlify.toml` remain untouched.
- All other Argo applications, Factory, Agentgateway, CNPG and backups remain
  unchanged by this PR.

## Before operator and data retirement

Follow `docs/operations/paperclip-prune-gates.md`. The live stage-1 inventory
confirmed no Paperclip Instance, server StatefulSet, server Service or server
HTTPRoute remains, while the operator, CRD, CNPG PVC/PV, backups, CNPG credential
ExternalSecret, Cilium policies and namespace remain. Explicitly classify each
before proposing the next separate PR.

The Instance was removed while its operator still existed and its finalization
completed. The operator can now be retired in a separate independently observed
sync. Do not treat removal of the operator Application as CRD deletion: the
Helm-kept CRDs require a separate, explicit cluster-scoped deletion decision
after confirming that no custom resources or API consumers remain.
Remove remaining AppProject/monitoring references only after no active
Paperclip objects are owned. Use GitOps; avoid blind `kubectl delete`.

## Regression contracts

`npm run check:paperclip-retirement-stage` verifies this Git-only boundary;
`npm run check:argocd-roots` guards ApplicationSet paths. Both intentionally
block accidental destructive removal until the contracts and proof are revised
with real runtime evidence.

No live cluster mutation is claimed until this change is reviewed, merged and
reconciled by Argo.
