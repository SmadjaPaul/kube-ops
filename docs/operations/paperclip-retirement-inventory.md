# Paperclip retirement — staged Git cleanup

Status (2026-10-16): **repository-only cleanup**, NOT live Paperclip decommission.

The existing #494 draft is reconciled onto current `main` without deleting
Kubernetes resources. Deletions only affect the obsolete Paperclip company
package, out-of-tree execution proof-of-concept, Paperclip-specific local CLI
preflights/tests and their harness references. Git history retains every file.

## Runtime explicitly retained until the operator finishes the prune proof

- `apps-ai` still renders `k8s/applications/ai/paperclip/` including Instance,
  CNPG Cluster, ScheduledBackup, ObjectStore, ExternalSecrets, namespace and
  NetworkPolicy. The existing SQL/WAL/PVC resources are not pruned.
- `apps-ai-paperclip-h3` remains present in the ApplicationSet and its
  corresponding directory/Kustomization remains intact. Do not delete a
  generated Application with `prune: true` without a live inventory.
- `infra-controllers` still manages the Paperclip operator Application and
  leader-election RBAC; this avoids orphaning a live Paperclip Instance while
  its CR finalizers are unknown.
- `velero-daily-paperclip` remains in the controller schedule root until its
  backup retention and content ownership are qualified.
- Docusaurus `website/` and `netlify.toml` remain untouched.
- All other Argo applications, Factory, Agentgateway, CNPG and backups remain
  unchanged by this PR.

## Before the separate runtime retirement

Follow `docs/operations/paperclip-prune-gates.md`. Collect and compare the
live **Argo managedResources** inventory and old/new Helm/Kustomize manifests
for apps-ai, apps-ai-paperclip-h3, infra-controllers, and the nested
paperclip-operator Application. Explicitly classify namespace finalizers,
Paperclip Instance finalizer, operator CRDs, CNPG PVC/PV, Velero backup,
ExternalSecret, Cilium policy, DNS/HTTPRoute and any shared dependency.

Remove the Paperclip Instance only while its operator still exists, wait
until operator finalization completes, confirm intended volumes/backup retention,
then decommission the operator in a later independently observed sync.
Remove remaining AppProject/monitoring references only after no active
Paperclip objects are owned. Use GitOps; avoid blind `kubectl delete`.

## Regression contracts

`npm run check:paperclip-retirement-stage` verifies this Git-only boundary;
`npm run check:argocd-roots` guards ApplicationSet paths. Both intentionally
block accidental destructive removal until the contracts and proof are revised
with real runtime evidence.

No live cluster diff, sync, data deletion or decommission is claimed.
