# Rules for k8s/

Repository rules, Safety and decisions: root `AGENTS.md`. These rules apply to manifests under `k8s/`.

## Workloads

- Set pod `hostNetwork: false`, `hostPID: false`, `hostIPC: false` (pod spec fields, not securityContext).
- Set pod securityContext `runAsNonRoot: true`, `runAsUser`, `runAsGroup`, `fsGroup`, `fsGroupChangePolicy: OnRootMismatch`.
- Set container securityContext `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`.
- Set CPU/memory requests and limits on every container, and a size limit on every emptyDir.
- Pin images to a specific tag, never `latest` or `main`.
- Never use `--force`, `--grace-period=0` or `--ignore-not-found`.
- Keep user documentation in `website/docs`; add no Markdown files under `k8s/` or `images/`.
- Commit with Conventional Commits (type and scope).

## Secrets

- Use ExternalSecret `external-secrets.io/v1` with ClusterSecretStore `doppler-cluster`, Doppler keys in UPPER_SNAKE_CASE, `refreshInterval: 1h`.
- For a CNPG database owned by the cluster application role, use the generated `<cluster>-app` Secret, not an ExternalSecret. A database owned by a separate managed role (`spec.managed.roles`) uses that role's `passwordSecret` (example: `k8s/clusters/oracle-a1/cnpg-cluster/cluster.yaml`).

## Network

- Every application namespace has CiliumNetworkPolicy v2 default-deny ingress and egress; never a standard NetworkPolicy.
- External access: HTTPRoute on `Gateway/external` (Cloudflare Tunnel → in-cluster cloudflared). LAN-only: HTTPRoute on `Gateway/internal`.
- No NodePort for external services, no wildcard certificates, no hardcoded legacy VIP ranges.

## Storage and backup

- Application PVCs use `longhorn-fast` or `longhorn-bulk` (single-replica, Talos UserVolumes); on oracle-a1 use `oci-bv`. Proxmox CSI is compatibility only, never the default class. No NFS.
- Velero/Kopia with `defaultVolumesToFsBackup: true` backs up PVC state to the R2 BackupStorageLocation `r2` (bucket homelab-backup-velero, prefix `velero/`; never move `archive/hetzner-legacy/`). No CSI snapshots for Proxmox CSI. Large media libraries are not backed up as volumes.
- Recovery order: Velero restore first, PV retain recovery if it fails.
- Longhorn backup target: R2 bucket homelab-backup-longhorn.

## PostgreSQL (CNPG)

- Every new database goes into the shared cluster `pg-shared` (D-2026-11-13-02). Exceptions and inventory: `docs/operations/cnpg-cluster-inventory.md`; `just check` refuses an unlisted `Cluster`.
- The oracle-a1 `pg-shared` has no backup: no durable data there until the conditions of `k8s/clusters/oracle-a1/README.md` are met.
- Backups use the barman-cloud plugin with an `ObjectStore` on R2 (bucket homelab-backup-cnpg), `isWALArchiver: true`, ScheduledBackup `method: plugin` with `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`. R2 ObjectStores set `AWS_REQUEST_CHECKSUM_CALCULATION` and `AWS_RESPONSE_CHECKSUM_VALIDATION` to `when_required`.
- Never introduce MinIO, Backblaze B2 or a new Hetzner store.

## Authentik blueprints

- Each blueprint file sets the schema reference and `version: 1`.
- Use `identifiers` for lookup and `attrs` for updates; states `present`, `created`, `must_created`, `absent` as intended.
- Use `!KeyOf` and `!Find` for intra-blueprint references, `!Env` for secrets from ExternalSecrets, `authentik_providers_oauth2.scopemapping` for OAuth property mappings.

## Home automation

- MQTT stays internal (Cilium TCP route). Zigbee2MQTT reaches the coordinator VM over the network only.
- `HA_SEED_ON_STARTUP: true` overwrites Home Assistant seed files; `false` preserves Home Assistant-managed files.
