# Add or retire a Kubernetes service — agent recipe

Authority: [AGENTS.md](../../AGENTS.md). Keep upstream Kubernetes/Helm/Kustomize and Git → Argo CD; **do not** create a second service DSL or a provisioning controller.

## Start with evidence

1. Run `just inventory`: Git-only Argo ApplicationSet roots and local Kustomize imports, **not** pod/runtime status. Inactive directories must never count toward node CPU requests.
2. Read `k8s/bootstrap/argocd-root/{applications,infrastructure}-applicationset.yaml`; Argo creates independent Applications per listed directory. The top-level `k8s/applications/kustomization.yaml` is not this list.
3. Copy the smallest *active* reference:
   - Stateless LAN service: `k8s/applications/tools/it-tools` (omit its KEDA-specific pieces unless justified).
   - Regular user app: `k8s/applications/catalog/mealie`.
   - Stateful app with CNPG/backup: `k8s/applications/catalog/paperless`.
   - Business Gateway and restore: `k8s/applications/business/invoice-ninja`.

## Minimal service contract

- ClusterIP Service and Gateway/internal HTTPRoute for a LAN app; no route for cluster-only API. Gateway/external is a **separately approved** capability with TLS/DNS, auth and network review.
- Declare CPU requests independently from CPU limits, using observed usage and workload latency. A missing request may inherit a declared limit. Right-size in PLT-53 after runtime metrics, not from dormant YAML.
- ESO / SOPS+age / Doppler secret delivery; no plaintext secrets in PR.
- Stateful storage deliberately chooses Longhorn class; CNPG/Barman or Velero/Kopia backup, ownership and restore test. Never prune a PVC as incidental cleanup.
- Exactly one scaling owner: fixed replicas by default, HPA for continuous appropriate signal, KEDA for justified queue/HTTP scaling, ARC for CI runners, Sandbox controller for SandboxClaims.

## Tests and delivery

1. Edit the *actual* parent root and render it: `kustomize build --enable-helm <root>`. Run `just check` and `just inventory`; verify the service is included in `activeKustomizationDirs`.
2. PR: identify the Argo Application owner, namespace, resources/limits, DNS/TLS exposure, ingress/egress, state/backup, rollout/rollback and agent test-result evidence.
3. Independent review and CI before merge. After merge prove **separately** STATIC, RECONCILED (Argo), RUNTIME (Pods/Services/routes) and USER if applicable. Follow `.agents/skills/runtime-observer/` and `just status-app <app>`.
4. Retirement: remove imports before deleting old manifests, classify retained state separately, check Argo prune ownership and existing PVC/PV and backup inventory. Never infer permission to erase data.

## Existing exception (2026-10-21)

`k8s/applications/restore` is referenced by the ApplicationSet but absent from Git, tracked by a narrow static-test waiver. Do **not** remove that Argo path without runtime owner/prune evidence. Listmonk/Twenty are retention-only Argo Applications and Paperclip still owns data rollback state. Dormant manifest deletion remains subject to an operator decision.
