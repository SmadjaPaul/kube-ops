Homelab GitOps monorepo built on Talos Kubernetes with Argo CD, OpenTofu, custom images, and Docusaurus documentation.

<Global_rules>
- Use subagents when possible to save context.
- Prefer to use skills when relevant.
- Apply durable cluster changes through GitOps and Argo CD. Imperative kubectl is allowed per operation inside the admitted scope defined in AGENTS.md Safety (runtime verification and same-day Git reconciliation required; write identity from PLT-237, read-only default until deployed).
- Always explicitly set pod spec hostNetwork false, hostPID false, hostIPC false; pod securityContext runAsNonRoot true, runAsUser, runAsGroup, fsGroup, fsGroupChangePolicy OnRootMismatch; container securityContext allowPrivilegeEscalation false, readOnlyRootFilesystem true, capabilities.drop ["ALL"]; and container resources cpu/memory requests and limits, even with custom values.
  - Note: hostNetwork, hostPID, and hostIPC are pod spec fields, not PodSecurityContext fields.
- Workloads must specify limits for emptyDir and all resource volumes.
- Run kustomize build --enable-helm on the changed path before commit.
- Use Conventional Commits with type and scope.
- Keep user-facing documentation in website/docs only.
- Avoid new markdown files inside k8s, tofu, and images.
- Avoid git commands unless the user requests them.
- NEVER use --force, --grace-period=0, and --ignore-not-found.
- Avoid secrets and generated artifacts in Git.
- Pin container images to specific tags. Never vague tags like latest or main.
</Global_rules>

<repo_paths>
- /k8s
- /tofu
- /images
- /website
</repo_paths>

<k8s>
<k8s_rules>
- Use ExternalSecret external-secrets.io/v1 with ClusterSecretStore doppler-cluster; Doppler remote keys use UPPER_SNAKE_CASE and refreshInterval 1h.
- Avoid ExternalSecret for CNPG application credentials; use CNPG auto-generated <cluster-name>-app secrets instead.
- Use Kubernetes Secret created by kubectl for service-to-service credentials.
- Use CiliumNetworkPolicy v2 with default-deny ingress and egress in every application namespace; never use standard NetworkPolicy resources.
</k8s_rules>
<k8s_network>
- Use Gateway API HTTPRoute for external access via Gateway/external (Cloudflare Tunnel -> in-cluster cloudflared).
- Use Gateway/internal for LAN-only routes with a stable Cilium LoadBalancer address.
- Use Cilium 1.20+ for TCP Gateway listeners.
- External hostnames resolve through Cloudflare Tunnel; do not hardcode legacy VIP ranges.
- Avoid NodePort for external services.
- Avoid wildcard DNS certificates.
</k8s_network>
<k8s_backup>
- Use Velero with Kopia filesystem backups; the default BackupStorageLocation `r2` targets Cloudflare R2 bucket homelab-backup-velero under prefix `velero/` (the bucket root also holds archive/hetzner-legacy/, never move it) (decision PLT-219/PLT-222, 12/11/2026). The Hetzner BSL `default` is ReadOnly (old backups stay restorable, nothing is deleted until a separate decision). Longhorn's single backup target is R2 bucket homelab-backup-longhorn (old Longhorn backups stay in the Hetzner bucket, prefix `longhorn/`).
- Use Velero restore before PV retain recovery; use PV retain recovery when Velero restore fails.
</k8s_backup>
<k8s_cnpg>
- Use ObjectStore CRD with barman-cloud plugin only.
- Continuous WAL and base backups are migrating from Hetzner Object Storage to Cloudflare R2 bucket homelab-backup-cnpg (decision PLT-219, runbook homelab-infra docs/operations/r2-migration.md), one Cluster at a time; do not reintroduce MinIO or Backblaze B2.
- A migrated Cluster points plugins barmanObjectName and its ScheduledBackup to an R2 ObjectStore with the per-bucket writer identity, endpoint from Doppler R2_S3_ENDPOINT, and AWS_REQUEST_CHECKSUM_CALCULATION and AWS_RESPONSE_CHECKSUM_VALIDATION set to when_required; keep its Hetzner ObjectStore as rollback target until an R2 restore is proven.
- Set plugin isWALArchiver true.
- Use ScheduledBackup method plugin with pluginConfiguration name barman-cloud.cloudnative-pg.io.
</k8s_cnpg>
</k8s>

<k8s_ai>
- Request nvidia.com/gpu resources and schedule GPU workloads on gpu-node labeled nodes.
- Use qdrant.ai.svc.cluster.local:6333 for vector storage and litellm.ai.svc.cluster.local:4000 for provider access.
- Store AI models on PVCs labeled backup.velero.io/backup-tier=GFS; avoid emptyDir for model storage.
</k8s_ai>

<k8s_litellm>
- Enable JWT auth with roles_jwt_field and jwt_litellm_role_map; avoid user_roles_jwt_field with jwt_litellm_role_map.
- Set JWT_PUBLIC_KEY_URL to the Authentik JWKS endpoint and GENERIC_SCOPE to include roles.
- Include proxy_admin in user_allowed_roles for admin UI access.
</k8s_litellm>

<k8s_automation>
- Keep MQTT internal-only; use Cilium TCP route for MQTT on Cilium 1.20+.
- Run Zigbee coordinator on a separate VM; connect Zigbee2MQTT to the coordinator over network only.
- Use HA_SEED_ON_STARTUP true to overwrite Home Assistant seed files; false to preserve Home Assistant-managed files.
</k8s_automation>

<k8s_media>
- Media PVCs use longhorn-fast or longhorn-bulk on the V1 single-node topology; no NFS, no TrueNAS.
- Avoid introducing NFS merely to preserve an upstream RWX shape; revisit cross-node storage when the topology does.
- Velero/Kopia backs up media state to Cloudflare R2; do not back up large media libraries as Kubernetes volumes.
</k8s_media>

<k8s_games>
- Use configMapGenerator with double underscore path keys to map into /data/plugins.
- Project all plugin ConfigMaps into one projected volume; use a sync init container to copy configs into /data/plugins.
- Avoid mounting ConfigMaps directly over /data.
- Avoid modifying volumeClaimTemplates after creation.
</k8s_games>

<authentik>
- Set blueprint schema reference and version 1 in each blueprint file.
- Use identifiers for lookup and attrs for updates.
- Use blueprint states present, created, must_created, and absent as intended.
- Use !KeyOf and !Find for intra-blueprint references; !Env for secrets sourced from ExternalSecrets.
- Use authentik_providers_oauth2.scopemapping for OAuth property mappings.
</authentik>

<controllers>
- Deploy Cert Manager before External Secrets, CNPG, and Argo CD.
- Use Argo CD Helm chart version 9.2.3 with ApplicationSet Git generator for discovery.
- Use Velero defaultVolumesToFsBackup true; avoid CSI snapshots for Proxmox CSI.
</controllers>

<storage>
- Longhorn is the V1 application storage plane; use storageClassName longhorn-fast or longhorn-bulk. Both are explicit single-replica classes on dedicated Talos UserVolumes.
- Proxmox CSI is compatibility/staged only; do not make it the default storage class for new V1 workloads.
- Proxmox CSI permissions and the kubernetes-csi@pve token are owned by homelab-infra; the runtime token reaches Kubernetes via ESO from the cluster/prd Doppler store. kube-ops must not contain a tofu/ tree.
</storage>

<database>
- Use one CNPG instance per application for V1; extra replicas provide no physical availability on the single AOOSTAR.
- Avoid shared databases across applications.
</database>

<network>
- Use Cilium kubeProxyReplacement enabled.
</network>

<website>
- Run npm run typecheck and npm run lint:all before commit.
- Update sidebars.ts when adding new docs pages.
- Avoid referencing AGENTS.md from documentation.
- Avoid code blocks in documentation; link to source files by absolute path.
- Avoid first-person plural and temporal language.
</website>
