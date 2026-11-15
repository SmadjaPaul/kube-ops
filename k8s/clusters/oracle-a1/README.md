# Oracle cluster (`oracle-a1`)

Cluster-local Argo CD in pull mode on this repository (D-2026-11-11-17). The
homelab Argo CD has no access to this cluster; nothing here routes to the LAN.

| Path | Role |
| --- | --- |
| `bootstrap/` | One-time operator `kustomize build --enable-helm k8s/clusters/oracle-a1/bootstrap \| kubectl apply --server-side -f -` (re-run once for CRD establishment): Argo CD, AppProject `oracle-a1`, root Application. Not synced by any Argo CD. |
| `apps/` | Root Application target (the only path it reads): child Applications, ordered by sync-wave. `cnpg-cluster` and `media` are kept out of `apps/kustomization.yaml` until PLT-190 (backup + restore proven off Oracle). |
| `guardrails/` | Cost guardrail (PLT-260): ValidatingAdmissionPolicy denying every Service `type: LoadBalancer` (Always Free; the OCI LB quota is set to zero in `terraform/oracle-a1`). |
| `external-secrets/` | Overlay on the shared ESO + `ClusterSecretStore/doppler-cluster` base. |
| `cnpg-operator/`, `cnpg-cluster/` | CNPG operator and the single shared `pg-shared` cluster (R2 backup, PLT-190). One `Database` + role per application. |
| `cert-manager/`, `cnpg-barman-plugin/` | CNPG barman-cloud plugin and its TLS prerequisite (PLT-301). No ACME issuer. |
| `hindsight/` | Agent memory (D-2026-11-14-03, PLT-301): dedicated CNPG cluster empty database (drill, PLT-303), Hindsight API, R2 backup. In the root. |
| `cloudflared/` | Outbound-only tunnel (token from Doppler). |
| `agent-operator/` | PLT-257: read-only agent identity (ServiceAccount `argocd/agent-operator`, ClusterRoles get/list/watch, no Secret, no pods/exec). In the root. Token: `scripts/agent-operator-oke-token.sh --provision` (run by Paul in an OKE admin session), then `kubectl-ro.sh --cluster oracle-a1 ...` reads it from Doppler `KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1`. |
| `netbird-router/` | PLT-256: NetBird routing peer for the admin path to the API (one `/32`, TCP 6443, group Admin). Namespace `cloudflared`. Out of the root until the one-off setup key `NETBIRD_SETUP_KEY_OKE` exists in Doppler `cluster/prd`; not activated by this change. The OCI Bastion stays the break-glass path. |
| `media/` | Overlay on the shared `applications/media/{polyfin,aiostreams}` bases. |
| `observability/` | Grafana Cloud export (PLT-306): kube-state-metrics with a metric allowlist and one Alloy, label `cluster=oracle-a1`, write token `GRAFANA_CLOUD_ORACLE_A1_WRITE_TOKEN`. In the root (PLT-309); no egress policy (flannel does not enforce NetworkPolicy). |

## Current state (PLT-328, 2026-11-15)

- Root Application `oracle-a1-root` reads `apps/`. It carries six children:
  `guardrails`, `external-secrets`, `cert-manager`, `cnpg-operator`,
  `cnpg-barman-plugin`, `observability`. Last read-only survey (2026-11-15):
  all `Synced/Healthy`, one arm64 node. This file does not assert it again.
- Retired from the root (PLT-328, decision of Paul): `ntfy` and `gatus`. Their
  namespaces are gone and AppProject `oracle-a1` no longer admits them. Alerts
  go through ntfy.sh (homelab Alertmanager receiver). Doppler keys
  `ORACLE_A1_NTFY_*` are kept. Rollback: Git revert.
- PLT-190: `cnpg-cluster` (`pg-shared` + R2 backup + drill database) joins the root for the off-Oracle restore drill. No application data goes there before the restore is proven.
- PLT-303: `hindsight` joins the root for the drill (empty database + test rows, nothing migrated from the homelab).
- Not in the root: `media`, `cloudflared`.
- Access: the Kubernetes API is private. The only path is an OCI Bastion
  port-forwarding session (`homelab-bastion`) with a temporary kubeconfig.
  No ARC runner and no homelab route reaches it. The NetBird path (PLT-256,
  `10.0.2.3:6443`) serves `kubectl-ro.sh --cluster oracle-a1` once the
  agent token exists (PLT-257).
- `bootstrap/project.yaml` is applied by the operator, never synced by Argo CD:
  a change to it takes effect on the cluster at the next operator bootstrap.

Prerequisites outside Git (bootstrap steps, none blocks the static manifests):
- The OKE cluster (homelab-infra#330, Basic, `FLANNEL_OVERLAY`, pods `10.248.0.0/16`,
  services `10.249.0.0/16` since the PLT-276 replace; no overlap with the homelab
  pods `10.244.0.0/16` or services `10.96.0.0/12`) and its `oci-bv` StorageClass; volumes are 50 Gi, the
  OCI block volume minimum (PLT-183).
- The `doppler-access-token` Secret in `external-secrets` (created by the operator on
  the Oracle cluster, never committed). Created by the operator on the Oracle cluster once it is reachable; its presence is runtime evidence, not asserted by this file.
- Doppler `cluster/prd` keys `ORACLE_A1_POSTGRES_PASSWORD` and
  `ORACLE_A1_CLOUDFLARE_TUNNEL_TOKEN`: both MISSING when checked (names only).
  Already present: `APP_POLYFIN_SECRET_KEY`, `APP_AIOSTREAMS_SECRET_KEY`,
  `APP_AIOSTREAMS_OPERATOR_AUTH`, `APP_AIOSTREAMS_OIDC_CLIENT_SECRET` (the inherited
  AIOStreams base activates its OIDC patch).
- Secret rotation (no Reloader on Oracle): change the value in Doppler, wait for the
  ExternalSecret refresh (1h, or annotate it to force), then restart the consumer
  (`cloudflared`, `polyfin`, `aiostreams`). For `ORACLE_A1_POSTGRES_PASSWORD`, CNPG
  applies the new role password from `pg-shared-polyfin`; restart `polyfin` afterwards
  so it reads the new `polyfin-db-app` URI.

Network: the OKE default CNI is flannel, which does not enforce NetworkPolicy, and
no Cilium is installed on Oracle. Homelab Cilium policies are removed from the
overlay and no policy is added; the Argo CD chart NetworkPolicies are inert.

## Backup: no application with data may be activated on Oracle

`pg-shared` is now configured (PLT-190) with the barman-cloud plugin: WAL
archive and daily base backups to `s3://homelab-backup-cnpg/oracle-a1/pg-shared/`
(R2, writer identity, 14 days retention), same model as `hindsight-db`. It is
in `apps/kustomization.yaml` since the activation PR of the drill
(`docs/operations/pg-shared-oke-backup-drill.md`, manifests in
`k8s/optional/pg-shared-oke-drill`). D-2026-11-11-17 forbids any single copy of
data on Oracle without a restore tested off Oracle. Until that restore is
proven (`NOT_TESTED` today), do not enable any application holding data
(Polyfin, AIOStreams PVCs, databases) here.
Open: arm64 digests to confirm at runtime.

Block volume plan (quota 200 GB = boot 50 + 3 x 50 Gi `oci-bv`; unit GB/GiB to
confirm at plan time): V1 `hindsight-db` (namespace `hindsight`), V2 `pg-shared`
(namespace `databases`), V3 reserve (dedicated Authentik cluster, or the
AIOStreams SQLite PVC in `media`). The drill uses no extra volume (restore runs
on the homelab; the OKE side only adds a database inside `pg-shared`).

## Hindsight (PLT-301, D-2026-11-14-03)

Hindsight is the agent memory. The homelab instance (`hindsight-personal`) stays
the only writer until the cutover.

- Database: dedicated CNPG `hindsight/hindsight-db`, bootstrapped EMPTY (initdb +
  `vector`) for the drill (PLT-303): no homelab data is migrated and the homelab
  archive is not read. Its own WAL archive and daily base backups go to
  `s3://homelab-backup-cnpg/oracle-a1/hindsight-db/` (writer identity), never
  into the homelab prefix.
- Image: PostgreSQL 17.7 standard trixie pinned to the multi-arch index digest;
  the homelab pin is the amd64-only manifest.
- Storage: one `oci-bv` volume of 50 Gi, no WAL volume. Block volumes on the
  tenancy: node boot volume + `pg-shared` (inactive) + Hindsight stay within
  the 200 GB Always Free quota.
- LLM: direct provider call with `APP_HINDSIGHT_OKE_LLM_API_KEY` (no route to
  the homelab Agentgateway). API and MCP require `Authorization: Bearer` with
  `APP_HINDSIGHT_MCP_API_KEY` (`ApiKeyTenantExtension`, schema `public`).
- NetworkPolicy is written but inert under flannel.
- Exposure: none. The public hostname is a maintained protection; the
  Cloudflare side is prepared in homelab-infra and stays disabled until Paul
  authorizes it.

Activation order (each step proven before the next):
1. OKE bootstrapped (PLT-253, PLT-276), cert-manager and barman plugin Healthy.
2. Drill (PLT-303): `hindsight.yaml` is in `apps/kustomization.yaml`; test rows
   seeded; first Oracle base backup Completed on R2.
3. Off-Oracle restore of `oracle-a1/hindsight-db` on the homelab
   (`k8s/optional/hindsight-oke-drill`), same fingerprint.
4. Real data migration from the homelab (separate step, PLT-305), then hostname activation (Paul), then agent cutover.

Rollback, in this order (the root prunes only the child Application object,
which has no resources finalizer, so its resources would keep running):
1. Git: set `api.replicaCount: 0` in `hindsight/values.yaml`; wait for the API
   Deployment at 0 replicas.
2. Git: remove `hindsight.yaml` from the root. The Cluster and its PVC stay
   (`Prune=false,Delete=false`); deleting them is a separate, explicit
   operation (a copy, never the only one while the homelab is the writer).
The homelab instance is never modified from this tree.

NetworkPolicy enforcement on OKE (PLT-258) is not a prerequisite of the drill:
the API requires a Bearer key and PostgreSQL requires a password over TLS.
It is listed as a residual risk of the hostname activation (PLT-304).
