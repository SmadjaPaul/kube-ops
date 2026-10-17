# Paperclip retirement — staged Git cleanup

Status (2026-10-17): **stage 1 runtime prune completed; execution-root cleanup
completed; operator GitOps retirement prepared; data retirement remains gated**.

PR #517 removed the Paperclip `Instance` from desired state and Argo pruned the
server workload. This change removes the now-unconsumed application runtime
ConfigMap, admin bootstrap ExternalSecret and application runtime ExternalSecret
from the desired state. It does not remove the operator, database, backups,
namespace, network policies or CNPG credentials.

The execution sandbox root `k8s/applications/ai-paperclip-h3` and its Git generator
entry are removed as a separate bounded change. This retires only the generated
H3 Application and its exclusive namespace/RBAC/policy resources; it does not
remove the `paperclip` namespace, CNPG/PVC/backup resources, the operator/CRD or
any Secret.

The existing #494 draft is reconciled onto current `main` without deleting
Kubernetes resources. Deletions only affect the obsolete Paperclip company
package, out-of-tree execution proof-of-concept, Paperclip-specific local CLI
preflights/tests and their harness references. Git history retains every file.

## Runtime explicitly retained for the next retirement gates

- `apps-ai` renders the Paperclip CNPG Cluster, ScheduledBackup, ObjectStore,
  namespace and NetworkPolicy. The Instance and application runtime secrets/config
  were removed in separate reviewed stages. The SQL/WAL/PVC resources are not
  pruned by this change.
- `apps-ai-paperclip-h3` is removed from the ApplicationSet and its corresponding
  directory by the bounded execution-root change. The live inventory identified
  only its exclusive `paperclip-exec-h3` namespace, quota/limit, ServiceAccount,
  RBAC and network-policy objects. Post-merge Argo pruning still requires a
  separate runtime observation.
- The `applications` AppProject destination allowlist retains
  `paperclip-exec-h3` for now; it is policy metadata, not a workload resource,
  and will be narrowed only after the namespace has been observed absent.
- The operator cleanup recovery reattached the Paperclip operator Application
  with its official cascade finalizer; Argo then removed the child Application,
  Deployment, Pod, Service, ReplicaSet and operator RBAC. This change removes
  the temporary chart source/destination permissions after that cascade proof.
  The live CRDs remain marked `helm.sh/resource-policy: keep` and are gated
  separately.
- The operator Application, leader-election RBAC, operator AppProject source and
  Paperclip-specific VPA target are removed by the operator-retirement change.
  The chart-generated CRDs are intentionally retained for a separate explicit
  deletion gate because the live chart marks them
  `helm.sh/resource-policy: keep`; no CR instances remain.
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
before proposing the next separate PR. The H3 execution-root PR was observed
separately before narrowing its policy allowlist.

The Instance was removed while its operator still existed and its finalization
completed. The operator can now be retired in a separate independently observed
sync. Do not treat removal of the operator Application as CRD deletion: the
Helm-kept CRDs require a separate, explicit cluster-scoped deletion decision
after confirming that no custom resources or API consumers remain.
The separate data namespace and its backup-covered resources remain retained
until the data-retirement gate is explicitly qualified. No data resource is
included in the operator cleanup.
Remove remaining AppProject/monitoring references only after no active
Paperclip objects are owned. Use GitOps; avoid blind `kubectl delete`.

## Regression contracts

`npm run check:paperclip-retirement-stage` verifies this Git-only boundary;
`npm run check:argocd-roots` guards ApplicationSet paths. The contracts retain
the operator/data safeguards while asserting that the retired H3 root is absent.

No live cluster mutation is claimed until this change is reviewed, merged and
reconciled by Argo.
