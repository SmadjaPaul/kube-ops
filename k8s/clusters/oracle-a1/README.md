# Oracle cluster (`oracle-a1`)

Cluster-local Argo CD in pull mode on this repository (D-2026-11-11-17). The
homelab Argo CD has no access to this cluster; nothing here routes to the LAN.

| Path | Role |
| --- | --- |
| `bootstrap/` | One-time operator `kubectl apply -k --enable-helm`: Argo CD, AppProject `oracle-a1`, root Application. Not synced by any Argo CD. |
| `apps/` | Root Application target (the only path it reads): child Applications, ordered by sync-wave. |
| `external-secrets/` | Overlay on the shared ESO + `ClusterSecretStore/doppler-cluster` base. |
| `cnpg-operator/`, `cnpg-cluster/` | CNPG operator and the single shared `pg-shared` cluster. One `Database` + role per application. |
| `cloudflared/` | Outbound-only tunnel (token from Doppler). |
| `media/` | Overlay on the shared `applications/media/{polyfin,aiostreams}` bases. |

Prerequisites outside Git: the `doppler-access-token` Secret in `external-secrets`,
the OKE cluster and its `oci-bv` StorageClass (homelab-infra), Doppler keys
`ORACLE_A1_POSTGRES_PASSWORD` and `ORACLE_A1_CLOUDFLARE_TUNNEL_TOKEN`.

Open items: no CNPG backup yet (needs off-Oracle storage and a tested restore
before any non-reconstructible data); no network policies (CNI to confirm);
StorageClass name and arm64 digests to confirm at runtime.
