Homelab GitOps repository for the current Smadja V1 platform.

<Global_rules>
- Git is the Kubernetes desired-state authority; Argo CD is the only steady-state reconciler.
- Runtime tools provide evidence. Do not create durable configuration with kubectl.
- Never log secrets, credentials, API keys, tokens, kubeconfigs, talosconfigs, or connection strings.
- Prefer boring upstream interfaces and the smallest reversible change.
- Run the repository validation relevant to every changed Kubernetes path before commit.
- Use Conventional Commits.
- Keep user-facing documentation under website/docs.
- Do not create new infrastructure abstractions, operators, DSLs, or controllers without a demonstrated need.
- Do not perform destructive cluster, storage, PKI, state, or backup mutations without explicit operator authorization.
</Global_rules>

<repo_boundary>
- homelab-infra owns Proxmox, Talos machine lifecycle and recovery material, UniFi/LAN, Cloudflare account/tunnel/DNS, Doppler bootstrap, Hetzner Object Storage, N100 and external SMTP.
- kube-ops owns Kubernetes bootstrap and Kubernetes/Argo desired state after kubeconfig handoff.
- kube-ops must not contain Terraform/OpenTofu providers or state.
</repo_boundary>

<cluster>
- Talos 1.13.10.
- Kubernetes 1.36.3.
- One schedulable Talos control-plane node for V1.
- Cilium 1.20.2 with kube-proxy replacement and Gateway API.
- Argo CD is the canonical GitOps reconciler.
</cluster>

<network>
- Public flow: Cloudflare wildcard DNS/tunnel -> Gateway/external -> HTTPRoute.
- Local flow: UniFi private DNS -> stable Gateway/internal VIP -> HTTPRoute.
- User-facing self-hosted applications should normally attach to Gateway/internal so they remain reachable on the LAN during WAN loss.
- Gateway/external is an explicit additional capability for remote access.
- Cluster-only backends should use Kubernetes Services directly and should not receive public routes without a demonstrated operator need.
- Private application DNS is derived from Gateway API desired state and synchronized into UniFi by the Kubernetes-owned private DNS controller.
- homelab-infra owns the UniFi/LAN capability, not the application hostname inventory.
- AdGuard is a filtering/cache resolver, not the application DNS authority.
- Do not use broad static LAN wildcard rewrites for *.smadja.dev.
- Do not remove an existing external route until its replacement LAN path has been proven.
- MQTT and Matter are local protocols; expose them only through compatible internal Gateway listeners when required.
- Avoid NodePort and accidental LoadBalancer exposure.
</network>

<storage>
- Longhorn 1.12.1 is the V1 application storage plane.
- Storage classes: longhorn-fast for latency-sensitive state and longhorn-bulk for capacity-oriented state.
- Both are single-replica V1 classes on dedicated Talos UserVolumes.
- Proxmox CSI remains compatibility/staged only; do not make it the default storage class for new V1 workloads.
- No TrueNAS/NFS dependency.
- Do not shrink/delete/move PVCs or change Longhorn replica/overcommit settings without fresh runtime evidence and explicit authorization.
</storage>

<backup>
- Velero with Kopia targets Hetzner Object Storage for Kubernetes/PVC disaster recovery.
- CloudNativePG with the Barman Cloud plugin targets Hetzner Object Storage for PostgreSQL base backups and continuous WAL archiving.
- Backup success is not restore success; representative application restores must be tested.
- Do not reintroduce MinIO or Backblaze B2 as active V1 backup targets.
- User data portability/export is separate from disaster-recovery backup.
</backup>

<secrets>
- Doppler is the external/bootstrap secret authority.
- External Secrets Operator is the Kubernetes delivery path.
- CNPG application credentials should use CNPG-managed application secrets where appropriate.
- Do not create service credentials with imperative kubectl if they can be declared through the existing authority path.
</secrets>

<identity>
- Authentik is the human identity authority.
- Durable cross-application identity should use the OIDC subject, not email or username.
- Email and username are mutable profile attributes.
- Keep the current Open WebUI account migration safe: do not disable email merging or replace the human-shaped bootstrap until the existing Paul/bootstrap state has been inspected and migrated after human enrollment.
- Do not reopen Argo SSO or Open WebUI OAuth provider settings without new runtime evidence.
</identity>

<automation>
- Home Assistant is first-class.
- Home Assistant may use hostNetwork where required for LAN discovery.
- MQTT, Zigbee2MQTT and Matter are local-first; keep their admin/control surfaces private unless an explicit remote consumer requires otherwise.
- HA-MCP is internal by default until a real external MCP consumer is defined with an appropriate remote-auth contract.
</automation>

<ai>
- Open WebUI, LiteLLM, Qdrant, GPT Researcher, Whisper and Pocket-TTS are supported V1/post-V1 components.
- Qdrant is a backend service; prefer ClusterIP/service discovery unless an operator UI/API need is demonstrated.
- The AOOSTAR V1 node has no discrete GPU. Do not add GPU resource requests to V1 workloads unless hardware changes.
</ai>

<validation>
- Run `npm run check:v1-contract` for Kubernetes contract changes.
- Render changed Kustomize roots with Helm enabled before commit when applicable.
- Treat live Argo/Kubernetes/UniFi evidence as required before changing assumptions about routes, DNS, storage, backups or identity.
</validation>

<forbidden_legacy>
Do not reintroduce active dependencies on:
- theepicsaxguy/homelab;
- peekoff.com;
- 10.25.150.x;
- Flux;
- TrueNAS/NFS;
- MinIO;
- Backblaze B2;
- Bitwarden secret stores;
- legacy LXC201/agent-dev;
- Windows gaming VM;
- a tofu/ infrastructure tree inside kube-ops.
</forbidden_legacy>
