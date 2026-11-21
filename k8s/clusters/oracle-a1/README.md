# Oracle cluster (`oracle-a1`, OKE)

Own Argo CD on this repository (D-2026-11-21-01, one Argo CD per cluster, same descriptor contract as the
homelab, `docs/operations/argo-app-descriptor.md`). Pull mode: the homelab holds no credential of this
cluster and nothing here routes to the LAN. The cluster was recreated empty on 2026-11-21: OKE BASIC,
one arm64 A1 node (2 OCPU, 12 GB), CNI `OCI_VCN_IP_NATIVE`, pods `10.248.0.0/16`, services
`10.249.0.0/16`, private API, no LoadBalancer allowed.

## Layout

| Path | Role |
| --- | --- |
| `bootstrap/` | Operator bootstrap, never synced: Argo CD (chart 10.3.3, v3.5.1, ApplicationSet controller on, no dex, no notifications), project `bootstrap`, Application `root`. |
| `argocd-root/` | What `root` reconciles: projects `infrastructure` and `apps`, ApplicationSet `infrastructure` (explicit folder list, Applications `infra-<folder>`), ApplicationSet `apps` (reads `k8s/applications/*/*/argocd-app.oracle-a1.yaml`, Applications `app-<name>`). |
| `guardrails/` | Baseline: ValidatingAdmissionPolicy denying `Service type: LoadBalancer` (PLT-260, Always Free). Only baseline component for now. |
| other folders | Legacy overlays (Flannel era: `hindsight`, `cnpg-*`, `media`, `observability`, `netbird-router`, `cloudflared`, `external-secrets`, `cert-manager`). Reconciled by nothing; stale. Revive one only by adding it to the `infrastructure` ApplicationSet list (and its namespaces to the `apps` project negations) after review, never silently. |

## Bootstrap (once, by Paul or an agent holding an admin kubeconfig)

The API is private: open the OCI Bastion (break-glass) or NetBird path first. Then, from this repository:

```
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig> --dry-run   # render only, no API call
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig>
```

(`just oke-bootstrap --kubeconfig <file>` is the same.) The script renders `bootstrap/`, applies
namespace, CRDs and Argo CD, waits for the CRDs, applies project `bootstrap` and `root`, waits for the
workloads and lists the Argo objects. Idempotent (server-side apply), it never reads or prints a Secret.
Afterwards `root` pulls `argocd-root/` from `main` and `infra-guardrails` must become Synced/Healthy.
Nothing is committed that needs the cluster: merge to `main` first, the Argo CD reads `main`.

Then, by Paul: Argo CD admin access is a local account (port-forward only, no ingress); the agent
identity is `scripts/agent-operator-oke-token.sh --provision` (server and CA are taken from the admin
session, which must be a private VCN `10.0.x.y` address), then `kubectl-ro.sh --cluster oracle-a1 ...`.

## Rules

- One cluster per app: `argocd-app.oracle-a1.yaml` or `argocd-app.yaml`, never both.
- No LoadBalancer (VAP and OCI quota zero); expose through Cloudflare Tunnel only, each hostname a decision of Paul.
- No application data on this cluster until a restore off Oracle is proven (PLT-190, `docs/operations/pg-shared-oke-backup-drill.md`).
- Images must have a `linux/arm64` manifest. Single node: PDBs use `maxUnavailable: 1`.
- The CNI does not enforce NetworkPolicy and no Cilium is installed here. The audit and PLT-384 describe a Cilium chaining baseline (CCNP `deny-imds`, `allow-egress-unisolated`, kube-ops#1620, not merged): it is not part of this tree, so IMDS is not blocked from pods yet.
- Secrets: nothing in Git. External Secrets is not installed yet (dedicated, restricted Doppler token to decide first).
