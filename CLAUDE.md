Homelab GitOps repository for the active Talos/Kubernetes platform.

<Global_rules>
- Git is the desired-state authority and Argo CD is the steady-state reconciler.
- Use runtime tools for evidence, not as a second durable mutation plane.
- Never log secrets, credentials, API keys, tokens, kubeconfig contents, Talosconfig contents, or connection strings.
- Prefer boring upstream interfaces and the smallest reversible change.
- Run the repository validation relevant to every changed path before merge.
- Use Conventional Commits.
- Keep user-facing documentation in website/docs.
- Do not add Terraform/OpenTofu to this repository.
- Do not use --force, --grace-period=0, insecure TLS bypasses, or destructive storage actions without explicit operator approval.
- Pin container images to specific versions or digests; do not use floating tags.
</Global_rules>

<repo_paths>
- /k8s
- /images
- /website
- /scripts
- /tests
</repo_paths>

<platform>
- Talos 1.13.10 and Kubernetes 1.36.3 run on the single V1 node homeops-01 / VM101.
- Cilium provides CNI, kube-proxy replacement, network policy, and Gateway API.
- Argo CD owns steady-state reconciliation.
- The AOOSTAR has no discrete GPU. GPU-only workloads remain disabled or staged.
</platform>

<secrets>
- Doppler is the external/bootstrap authority.
- External Secrets Operator delivers Kubernetes runtime secrets through ClusterSecretStore doppler-cluster.
- Do not reintroduce Bitwarden bindings.
- Prefer CNPG-generated application credentials for CNPG application users.
</secrets>

<storage>
- Longhorn is the V1 application storage layer.
- Use longhorn-fast for latency-sensitive state and longhorn-bulk for capacity-oriented state.
- Proxmox CSI is compatibility/staged only; do not make it the default storage class for new workloads.
- Do not add TrueNAS/NFS dependencies to the active V1 platform.
- Do not shrink/delete PVCs or change replica/overcommit settings from static reasoning alone.
</storage>

<backup>
- Velero with Kopia targets Hetzner Object Storage for Kubernetes/PVC disaster recovery.
- CNPG uses the Barman Cloud plugin with Hetzner Object Storage for base backups and continuous WAL.
- Do not use MinIO or Backblaze B2 as active backup targets.
- Backup success is not restore proof; application-level restore is the acceptance criterion.
</backup>

<network>
- Public subdomains follow Cloudflare wildcard DNS -> Cloudflare Tunnel -> Gateway/external -> HTTPRoute.
- Gateway/internal is the LAN path.
- User-facing self-hosted applications should normally attach to Gateway/internal; Gateway/external is an explicit additional capability.
- Backend-only services should use ClusterIP/service DNS unless a real operator-facing route is required.
- The post-V1 private DNS target is ExternalDNS sourced from Gateway API, filtered to Gateway/internal, synchronizing records into UniFi.
- homelab-infra owns UniFi/LAN capability, not Kubernetes application hostnames.
- AdGuard is filtering/cache, not the application DNS authority.
- Do not hard-code the upstream reference network 10.25.150.x.
- Avoid NodePort for application exposure.
</network>

<home_automation>
- Home Assistant is allowed to use hostNetwork when required for LAN discovery; do not apply a blanket hostNetwork=false rule to it.
- MQTT and Matter transport stay LAN/internal.
- Zigbee2MQTT connects to the network coordinator and MQTT; its admin UI should become LAN-only only after the LAN Gateway/private DNS path is proven.
- HA-MCP exposure depends on its real consumer. Internal-only is the default unless an external client requires a reviewed remote-auth contract.
</home_automation>

<identity>
- Authentik is the human identity authority.
- OIDC sub is the durable identity key; email and username are mutable profile attributes.
- Do not merge the old PR #89 Open WebUI bootstrap/merge-by-email changes until Paul enrollment and the existing Open WebUI bootstrap account migration are proven at runtime.
- Synthetic users must remain non-admin unless the test explicitly targets admin behavior.
</identity>

<database>
- CNPG uses one instance per application for the single-node V1.
- Avoid shared databases across applications.
- Use the barman-cloud plugin ObjectStore path for backup/WAL.
</database>

<validation>
- Run npm run check:v1-contract for Kubernetes desired-state changes.
- Render changed Kustomize roots with Helm enabled when applicable.
- Treat Argo Synced/Healthy, pod readiness, HTTP probes, and browser/OIDC E2E as separate evidence layers.
</validation>
