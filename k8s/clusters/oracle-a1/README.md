# Oracle cluster (`oracle-a1`)

Cluster-local Argo CD in pull mode on this repository (D-2026-11-11-17). The
homelab Argo CD has no access to this cluster; nothing here routes to the LAN.

| Path | Role |
| --- | --- |
| `bootstrap/` | One-time operator `kustomize build --enable-helm k8s/clusters/oracle-a1/bootstrap \| kubectl apply --server-side -f -` (re-run once for CRD establishment): Argo CD, AppProject `oracle-a1`, root Application. Not synced by any Argo CD. |
| `apps/` | Root Application target (the only path it reads): child Applications, ordered by sync-wave. `cnpg-cluster` and `media` are kept out of `apps/kustomization.yaml` until PLT-190 (backup + restore proven off Oracle). |
| `external-secrets/` | Overlay on the shared ESO + `ClusterSecretStore/doppler-cluster` base. |
| `cnpg-operator/`, `cnpg-cluster/` | CNPG operator and the single shared `pg-shared` cluster. One `Database` + role per application. |
| `cloudflared/` | Outbound-only tunnel (token from Doppler). |
| `media/` | Overlay on the shared `applications/media/{polyfin,aiostreams}` bases. |

Prerequisites outside Git (bootstrap steps, none blocks the static manifests):
- The OKE cluster (homelab-infra#330, Basic, `FLANNEL_OVERLAY`, pods `10.244.0.0/16`,
  services `10.245.0.0/16`) and its `oci-bv` StorageClass; volumes are 50 Gi, the
  OCI block volume minimum (PLT-183).
- The `doppler-access-token` Secret in `external-secrets` (created by the operator on
  the Oracle cluster, never committed). Not existing yet: the cluster does not exist.
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

There is deliberately no Barman/backup on `pg-shared` yet (needs off-Oracle object
storage, cert-manager for the Barman plugin, and a restore tested outside Oracle).
D-2026-11-11-17 forbids any single copy of data on Oracle without a restore tested
off Oracle. Until the CNPG backup ticket is done and a restore has been proven, do
not enable any application holding data (Polyfin, AIOStreams PVCs, databases) here.
Open: arm64 digests to confirm at runtime.
