# AGENTS.md — kube-ops operating contract

## Authority

Git is the desired-state authority. Argo CD reconciles Kubernetes. Runtime tools provide evidence; they are not a second mutation plane.

Repository boundary:
- `kube-ops`: disposable Talos VM lifecycle for the clean cluster plus Kubernetes/Argo desired state.
- `homelab-infra`: physical/external infrastructure, UniFi/LAN, Cloudflare account/tunnel/DNS, Doppler bootstrap, Hetzner Object Storage, Migadu and other external prerequisites.

## V1 deployment contract

- `main` must remain deployable from a clean environment in one bootstrap path.
- V1 is one schedulable Talos control-plane node at VM101 / 10.0.20.60.
- Talos is v1.13.10 and Kubernetes is 1.36.3.
- Cilium is bootstrapped before Argo CD.
- Argo CD is the only steady-state Kubernetes reconciler.
- `proxmox-csi` on the local Proxmox datastore is the canonical StorageClass.
- V1 is single-node/RWO. Do not introduce RWX/NFS/TrueNAS assumptions.
- CNPG uses one instance per application for V1; HA requires a later multi-node topology.
- CNPG durability is Barman Cloud -> Hetzner Object Storage with continuous WAL and weekly base backups.
- Velero/Kopia -> Hetzner protects non-database persistent data.
- Doppler is the external/bootstrap secret authority; ESO delivers runtime secrets through `ClusterSecretStore/doppler-cluster`.
- Authentik is the OIDC authority.
- Migadu remains the SMTP provider for V1.
- GPT Researcher, Pocket-TTS and Whisper remain in V1.
- vLLM, Frigate, Minecraft and the business stack stay outside the first-green deployment.
- Public subdomain exposure is `*.smadja.dev -> Cloudflare Tunnel -> external Gateway -> HTTPRoute`.

## Forbidden legacy bindings

No active desired state may contain:
- `theepicsaxguy/homelab`
- `peekoff.com`
- `10.25.150.x`
- TrueNAS/NFS media dependencies
- MinIO or Backblaze B2 backup targets
- Bitwarden secret-store bindings
- `proxmox-csi-2`

## Workflow

```text
inspect -> isolated branch -> smallest change -> render/validate -> PR -> review -> merge -> Argo -> runtime proof
```

Do not mutate steady-state Kubernetes outside Git/Argo. Do not expose, log or commit secrets.

For Kubernetes changes:
- run `npm run check:v1-contract`;
- render every changed Kustomize root with `kustomize build --enable-helm`;
- keep image tags pinned;
- keep resource requests/limits explicit;
- keep pod/container security contexts explicit;
- keep application namespaces default-deny with Cilium policy.

For OpenTofu changes:
- run `tofu fmt -check` and `tofu validate`;
- produce a plan before apply;
- never use `--auto-approve`, targeted apply or manual state edits for normal operation.

A live apply or destructive Proxmox action always requires explicit operator approval.
