# Paperclip retirement: Argo prune gates before #494

Status: **STATIC GUARD IMPLEMENTED; RUNTIME PRUNE NOT QUALIFIED.** This file does not authorize a cluster mutation.

## Problem found on 2026-10-16

Draft [kube-ops #494](https://github.com/SmadjaPaul/kube-ops/pull/494) deletes `k8s/applications/ai-paperclip-h3` while the active `applications` ApplicationSet still generates it from `k8s/bootstrap/argocd-root/applications-applicationset.yaml` with automated `prune: true`. Removing the directory without changing its generator is an invalid GitOps state. Removing the generator entry instead may delete the generated Application and its managed cluster resources. Neither outcome qualifies as a safe retirement without live ownership evidence.

The `infra-controllers` generated Application includes the Paperclip operator; its removal may affect Paperclip CRDs, namespace-scoped controllers, and PVC/backup ownership. Remove both the server and operator in deliberate phases.

The same generator already references `k8s/applications/restore`, a missing directory on `main` as of 2026-10-16. This is an explicitly recorded historical exception in `tests/harness/argocd-generator-paths.test.mjs`, **not** proof that removing the entry or creating an empty Kustomization is safe.

## Required read-only inventory

Before allowing #494's live Paperclip removals, gather at the *current deployed revision*:

1. List the Argo Applications and their sources/last syncs, especially `apps-ai`, `apps-ai-paperclip-h3` and `infra-controllers`; separately identify any operator Application.
2. Export each Application's managed-resource inventory, including resource UID and namespace; identify which objects would be pruned by the proposed rendered manifests.
3. Enumerate Paperclip-only CNPG clusters, associated PV/PVCs, ownership references/finalizers, active snapshots, Velero schedules and restore points. Record which resources are **shared** with Factory, monitoring, or other workloads.
4. Compare a complete `kustomize build` / Helm render of `main` and the branch head. For each removal, record `kind/namespace/name` and explicit owner. Run `argocd app diff` read-only as an additional check, not as a replacement for the resource inventory.
5. Classify each removal as (a) stateless workload, (b) credential/service/integration, (c) cluster-scoped CRD/operator, (d) durable data/storage/backup. Only Paperclip-exclusive resources may be decommissioned; no unrelated shared resources.
6. Keep Docusaurus `website/` and `netlify.toml` untouched. Its continued availability is independent of the Paperclip runtime.

Do not paste passwords, tokens, Secret values, or database contents into tickets or PRs. Evidence should be metadata and resource identifiers only.

## Safe rollout sequence

- Preserve desired-state data-only retention roots if an object's backup or deletion ownership is still unclear, following the existing Listmonk/Twenty retention pattern in the ApplicationSet.
- First remove confirmed Paperclip-only stateless workloads with a reviewed bounded prune set. Verify Argo health, orphaned resources and non-Paperclip app health.
- Separately remove unneeded operators, RBAC, ExternalSecrets and network rules after confirming no dependent resources remain. Handle retained PVCs/PVs, CNPG and backups explicitly.
- Finally narrow unused AppProject destinations, generator roots, VPA selectors, blackbox probes, alert rules, secrets and DNS only after observing their actual absence.
- Update Linear PLT-43/PLT-46 with the pre/post inventory and cleanup follow-up. An automated `Synced` status alone does not qualify data retention or successful recovery.

## Regression contract

`npm run check:argocd-roots` asserts that explicit ApplicationSet Git directory roots have valid Kustomizations (apart from the one preexisting `restore` exception) and that the Docusaurus site is retained. **It does not establish prune safety.** #494 will need a clean rebase and live-backed removal proof before merge.
