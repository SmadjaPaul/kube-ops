Homelab GitOps repository built on Talos Kubernetes with Argo CD, custom images, and Docusaurus documentation. External infrastructure and Talos lifecycle IaC belong to SmadjaPaul/homelab-infra.

<Global_rules>
- Always use parallel subagents to save context, time and stay on track.
- Use available skills for any task when possible. Skills encode established workflows.
- Never log secrets, credentials, API keys, tokens, or connection strings.
- All warnings must be resolved. Lint, type, complexity, and compiler warnings fail CI.
- A PR must read like one author: match the naming, structure, DI style, and error handling shape of the surrounding code.
- A file exceeding 300 lines likely has more than one responsibility and must be split.
- Apply all cluster changes through GitOps and Argo CD unless the user approves manual kustomize and kubectl.
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
- never create any markdown docuemnts, summary or analyzis etc if the user havent told you to do so.
</Global_rules>

<repo_paths>
- /k8s
- /images
- /website
- /scripts
- /tests
</repo_paths>

<k8s>
<k8s_rules>
- Use ExternalSecret external-secrets.io/v1 with ClusterSecretStore doppler-cluster; Doppler remote keys use UPPER_SNAKE_CASE and refreshInterval 1h.
- Avoid ExternalSecret for CNPG application credentials; use CNPG auto-generated <cluster-name>-app secrets instead.
- Use Kubernetes Secret created by kubectl for service-to-service credentials.
- Use CiliumNetworkPolicy v2 with default-deny ingress and egress in every application namespace; never use standard NetworkPolicy resources.
</k8s_rules>
<k8s_network>
- Use Gateway API HTTPRoute for application routing.
- Public exposure is Cloudflare Tunnel -> in-cluster cloudflared -> Cilium Gateway -> HTTPRoute.
- Use internal routes for services that must not be publicly exposed.
- Use Cilium 1.18+ for TCP Gateway listeners.
- Avoid NodePort for external services.
- Wildcard public DNS/certificates are allowed only through the canonical Cloudflare/cert-manager path.
</k8s_network>
<k8s_backup>
- Use Velero with Kopia filesystem backups for ordinary Kubernetes PVC state.
- V1 backup storage is Hetzner Object Storage in fsn1; do not add MinIO or Backblaze B2 targets.
- Use filesystem backup rather than CSI snapshots for the V1 offsite path.
- Treat application-level restore verification as required evidence; a completed Backup object alone is insufficient.
</k8s_backup>
<k8s_cnpg>
- Use ObjectStore CRD with the barman-cloud plugin only.
- Store continuous WAL and scheduled base backups in the canonical Hetzner Object Storage bucket under application-specific cnpg prefixes.
- Set plugin isWALArchiver true.
- Use ScheduledBackup method plugin with pluginConfiguration name barman-cloud.cloudnative-pg.io.
- Do not treat Velero as the PostgreSQL PITR mechanism.
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
- Keep MQTT internal-only; use Cilium TCP route for MQTT on Cilium 1.18+.
- Run Zigbee coordinator on a separate VM; connect Zigbee2MQTT to the coordinator over network only.
- Use HA_SEED_ON_STARTUP true to overwrite Home Assistant seed files; false to preserve Home Assistant-managed files.
</k8s_automation>

<k8s_media>
- Use the V1 Longhorn storage classes for in-cluster media/application PVCs: longhorn-fast for latency-sensitive state and longhorn-bulk for capacity-oriented state.
- Do not reintroduce TrueNAS/NFS media dependencies into active V1 state.
- Exclude reproducible caches, downloads, thumbnails, and other Derived data from backup when safe.
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
- Use Velero defaultVolumesToFsBackup true for stateful application schedules; avoid CSI snapshots for the V1 offsite backup path.
</controllers>

<storage>
- Proxmox CSI remains available for existing/staged V1 compatibility; Longhorn is the preferred V1 application storage path where manifests already use longhorn-fast or longhorn-bulk.
- Longhorn uses the dedicated Talos fast and bulk data paths declared in k8s/infrastructure/storage/longhorn.
- Do not make a storage class default implicitly; application manifests should select the intended class explicitly.
- Do not add a new NFS, TrueNAS, or in-cluster object-storage dependency as a prerequisite for V1.
</storage>

<database>
- Use one CNPG instance per application for the single-node V1 unless the deployment contract is deliberately changed.
- Avoid shared databases across applications.
- Protect PostgreSQL with Barman Cloud WAL archiving and tested recovery procedures.
</database>

<network>
- Use Cilium kubeProxyReplacement enabled.
</network>

<external_iac>
- Terraform/OpenTofu files are forbidden in kube-ops.
- External infrastructure, Proxmox/Talos lifecycle, Cloudflare account resources, Doppler bootstrap, and Hetzner Object Storage belong to SmadjaPaul/homelab-infra.
</external_iac>

<website>
- Run npm run typecheck and npm run lint:all before commit.
- Update sidebars.ts when adding new docs pages.
- Avoid referencing AGENTS.md from documentation.
- Avoid code blocks in documentation; link to source files by absolute path.
- Avoid first-person plural and temporal language.
</website>
