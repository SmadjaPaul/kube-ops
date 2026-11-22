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
| `guardrails/` | Baseline: ValidatingAdmissionPolicy denying `Service type: LoadBalancer` (PLT-260, Always Free). |
| `agent-operator/` | Read-only agent identity (ServiceAccount, RBAC without Secret data). |
| `external-secrets/` | External Secrets Operator (base `k8s/infrastructure/controllers/external-secrets`) with only the ClusterSecretStore `doppler-cluster`. The overlay removes what OKE cannot run: PrometheusRule and ServiceMonitors (no Prometheus Operator CRD), stores `k8s-auth` and `k8s-databases`. The base is untouched (homelab render identical). |
| `netbird-router/` | NetBird routing peer `oke-oracle-a1-router` (namespace `netbird`, PSA `privileged`, needs NET_ADMIN/SYS_ADMIN/SYS_RESOURCE) : admin and agent path to the private API (PLT-256). Setup key from ExternalSecret `NETBIRD_SETUP_KEY_OKE` via `doppler-cluster`. Image `netbirdio/netbird:0.83.0` has a `linux/arm64` manifest. |
| other folders | Legacy overlays (Flannel era: `hindsight`, `cnpg-*`, `media`, `observability`, `cloudflared`, `cert-manager`). Reconciled by nothing; stale. Revive one only by adding it to the `infrastructure` ApplicationSet list (and its namespaces to the `apps` project negations) after review, never silently. |

## Bootstrap (once, by Paul or an agent holding an admin kubeconfig)

The API is private: open the OCI Bastion (break-glass) or NetBird path first. Then, from this repository:

```
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig> --dry-run   # render only, no API call
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig>
```

(`just oke-bootstrap --kubeconfig <file>` is the same.) The script renders `bootstrap/`, applies
namespace, CRDs and Argo CD, waits for the CRDs, applies project `bootstrap` and `root`, waits for the
workloads and lists the Argo objects. Idempotent (server-side apply), it never reads or prints a Secret.
Afterwards `root` pulls `argocd-root/` from `main` and `infra-guardrails`, `infra-agent-operator` and
`infra-external-secrets` must become Synced/Healthy. Order: Argo CD, ESO, the Doppler token Secret
(gesture below), then `infra-netbird-router` (it retries until the store is Ready; ESO objects use
sync-wave 0, the store wave 1) and the NetBird peer appears in group `OKE Routers`.
Nothing is committed that needs the cluster: merge to `main` first, the Argo CD reads `main`.

### One-off gesture by Paul: Doppler token for External Secrets

`infra-external-secrets` syncs without it, but the store `doppler-cluster` stays not Ready, so
`netbird-router` (and any later ExternalSecret) gets no secret until the Secret
`doppler-access-token` exists in `external-secrets`. It is not in Git. Once the namespace exists
(created by the Application), create it from a read-only Doppler token of the config that
`doppler-cluster` serves. The store sets no project: the token decides, and that is `cluster/prd`
(the same config as every other ExternalSecret of this repository). Run it where `kubectl` reaches
the API (NetBird or Bastion) and `doppler` is logged in as Paul; the value goes through a pipe,
never to the terminal or a file; the Secret key must be exactly `token`:

```
doppler configs tokens create oke-oracle-a1-eso --project cluster --config prd --access read --plain \
  | tr -d '\n' \
  | kubectl --kubeconfig <admin-kubeconfig> -n external-secrets create secret generic doppler-access-token \
      --from-file=token=/dev/stdin
```

Check without reading the value: `kubectl -n external-secrets get clustersecretstore doppler-cluster`
shows `Valid` / `Ready`, then `kubectl -n netbird get externalsecret netbird-router-setup-key`.

Prerequisite in homelab-infra (not here): `terraform/netbird` writes `NETBIRD_SETUP_KEY_OKE` to
Doppler `infrastructure/prd` by default (`doppler_project`), not to `cluster/prd`. The ExternalSecret
reads `cluster/prd`, so the key must exist there (set `doppler_project = "cluster"` for that
secret, or copy it); never widen the OKE token to `infrastructure/prd`, which holds operator
credentials. The same root creates the setup key bound to the NetBird group `OKE Routers` (one-off,
`auto_groups`), which is how the pod joins that group; the key must be unused and unexpired when the
pod first starts (enrolment state then lives in `/var/lib/netbird-router` on the node).

Then, by Paul: Argo CD admin access is a local account (port-forward only, no ingress); the agent
identity is `scripts/agent-operator-oke-token.sh --provision` (server and CA are taken from the admin
session, which must be a private VCN `10.0.x.y` address), then `kubectl-ro.sh --cluster oracle-a1 ...`.

## Rules

- One cluster per app: `argocd-app.oracle-a1.yaml` or `argocd-app.yaml`, never both.
- No LoadBalancer (VAP and OCI quota zero); expose through Cloudflare Tunnel only, each hostname a decision of Paul.
- No application data on this cluster until a restore off Oracle is proven (PLT-190, `docs/operations/pg-shared-oke-backup-drill.md`). Enforced by `scripts/check-argo-app-descriptors.sh` (PVC, CNPG `Cluster`, StatefulSet with volumeClaimTemplates refused); exception: `disposableData: "<reason>"` in the descriptor, for disposable and rebuildable data only.
- Images must have a `linux/arm64` manifest. Single node: PDBs use `maxUnavailable: 1`.
- The CNI does not enforce NetworkPolicy and no Cilium is installed here (so an OKE app carries no CiliumNetworkPolicy: `policy-check.sh` and `app-test.sh` exempt apps with `argocd-app.oracle-a1.yaml`; remove that exemption with the Cilium baseline). The audit and PLT-384 describe a Cilium chaining baseline (CCNP `deny-imds`, `allow-egress-unisolated`, kube-ops#1620, not merged): it is not part of this tree, so IMDS is not blocked from pods yet.
- Secrets: nothing in Git. External Secrets reads Doppler `cluster/prd` through `doppler-cluster` with a read-only token that only Paul creates (gesture above). An ExternalSecret of a new app must name a key present in that config.
