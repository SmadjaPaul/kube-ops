# Paperclip retirement — staged Git cleanup

Status (2026-10-17): **stage 1 runtime prune completed; stage 2 stateless cleanup and
execution-root retirement prepared**.

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
- `infra-controllers` still manages the Paperclip operator Application and
  leader-election RBAC; the operator remains until all CRD and data dependencies
  are reviewed separately.
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
before proposing the next separate PR. The H3 execution-root PR must be observed
separately before narrowing the AppProject destination allowlist.

Remove the Paperclip Instance only while its operator still exists, wait
until operator finalization completes, confirm intended volumes/backup retention,
then decommission the operator in a later independently observed sync.
Remove remaining AppProject/monitoring references only after no active
Paperclip objects are owned. Use GitOps; avoid blind `kubectl delete`.

## Regression contracts

`npm run check:paperclip-retirement-stage` verifies this Git-only boundary;
`npm run check:argocd-roots` guards ApplicationSet paths. The contracts retain
the operator/data safeguards while asserting that the retired H3 root is absent.

No live cluster mutation is claimed until this change is reviewed, merged and
reconciled by Argo.
