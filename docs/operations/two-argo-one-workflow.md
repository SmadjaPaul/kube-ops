# Two Argo CD instances, one agent workflow

Status: ACTÉE (homelab-infra `docs/decisions.md` D-2026-11-15-01). Date: 2026-11-15. Owner: Paul. Ticket: PLT-163 / PLT-306 tranche.

## Decision

Keep two independent Argo CD instances: one on the homelab Talos cluster, one on OKE (`oracle-a1`, pull mode, one node of 2 OCPU / 12 GB). Both reconcile the same repository, `kube-ops` `main`. One workflow serves both: branch, `just check`, PR, merge, `just verify-delivery CLUSTER APP`. No central Argo CD. No Argo CD Agent.

## Comparison

| Criterion | Two independent Argo CD (chosen) | One central Argo CD for both clusters | Argo CD Agent |
|---|---|---|---|
| Simplicity for agents | Same Git workflow and same verification command; no UI. Cluster = one folder. | One UI/API. Needs cluster registration and per-cluster Projects. | One UI, plus agent and principal components to operate. |
| Resources on OKE | Argo CD trimmed in `bootstrap/values.yaml` (no dex, notifications, applicationset): requests 70m CPU / 480 Mi in total. | Smallest: only a cluster Secret on OKE. | An agent on OKE, plus a principal and its PKI on the homelab. |
| Isolated failure | Full. An outage of one Argo CD leaves the other cluster reconciling. | None. The homelab Argo CD is a single point of failure for OKE, and OKE credentials sit on the homelab. | Partial. The agent keeps its cache when the principal is down, but new changes stop. |
| Security | No inbound path to either cluster. The homelab holds no OKE credential (D-2026-11-11-17). | The homelab holds an OKE admin credential; OKE API reachable from the homelab. | A new mTLS control path and a new component to patch. |
| Measured benefit | Not applicable: nothing to measure. | None measured. | None: it federates two clusters that need no federation. |

## Reasons

1. The agent never uses the Argo CD interface. Git and Grafana Cloud give one view of both clusters: `cluster` label `homelab` or `oracle-a1`.
2. A central Argo CD adds a single point of failure and a cross-cluster credential. It brings no operational benefit measured today.
3. Argo CD Agent adds components for federation only. Paul excluded it.

Revisit only with a measured benefit written in a ticket (for example: more than two clusters, or a repeated multi-cluster rollout need).

## Convention (no migration)

- Shared base: `k8s/applications/<group>/<app>`. It is cluster-neutral where possible.
- Homelab: the base directory is the application. The ApplicationSet `applications` generates `apps-<app>`.
- OKE: the folder `k8s/clusters/oracle-a1/<app>/` is an overlay on the same base (`resources: ../../../applications/<group>/<app>`), with patches for what differs. `apps/<app>.yaml` is its Application, listed in `apps/kustomization.yaml`.
- Choice of cluster = choice of folder. Create the OKE side with `just scaffold-oke-app <group>/<app> <name> <namespace>`.
- Data stays off OKE until PLT-190 (the scaffold refuses a base with a PVC or a CNPG Cluster).

## Verification

`just verify-delivery <homelab|oracle-a1> <app> [--since MERGE_EPOCH --timeout 1200]` returns PASS or FAIL (exit 0, 1; 2 = BLOCKED). It reads Grafana Cloud (`GRAFANA_AGENT_READ_TOKEN`): `argocd_app_info` (Synced, Healthy, fresh sample) and `kube_pod_status_ready` of the destination namespace (completed pods excluded).

Limits: evidence level RUNTIME only. The Argo metric has no revision, so `REVISION=NOT_PROVEN`; `--since` waits for one Argo refresh and one scrape. A missing series is a collection gap, reported as FAIL, never as healthy.
