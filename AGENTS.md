# AGENTS.md — kube-ops operating router

## Authority

Git is the desired-state authority. Argo CD reconciles Kubernetes. Runtime tools are evidence, never a second mutation plane.

Repository boundary:
- `kube-ops`: Talos VM lifecycle owned here for the clean cluster plus Kubernetes/Argo desired state.
- `homelab-infra`: physical/external infrastructure, UniFi/LAN, Cloudflare account/tunnel/DNS, Doppler bootstrap, Hetzner Object Storage and other external prerequisites.

## Normal workflow

```text
inspect -> isolated branch -> smallest change -> render/validate -> PR -> review -> merge -> Argo -> runtime proof
```

Do not perform steady-state Kubernetes mutations outside Git. Do not self-merge protected branches unless the operator explicitly authorizes that exact merge.

## Architecture invariants

- One schedulable Talos control-plane node for V1.
- `proxmox-csi` is the canonical Kubernetes StorageClass; V1 is RWO/single-node, not RWX.
- CNPG databases use one instance unless a later physical-node topology makes HA meaningful.
- CNPG durability is Barman Cloud -> Hetzner Object Storage: continuous WAL, weekly base backup, 14-day recovery window.
- Velero/Kopia -> Hetzner protects non-database persistent data.
- Doppler is external/bootstrap authority; ESO delivers runtime secrets through `ClusterSecretStore/doppler-cluster`.
- OpenBao is bounded to Omnigent Transit and is not the general secret manager.
- Authentik is the OIDC authority.
- Public subdomain exposure is `*.smadja.dev -> Cloudflare Tunnel -> external Gateway -> HTTPRoute`.
- Per-application Cloudflare tunnel ingress rules are forbidden; the wildcard tunnel contract is external infrastructure.
- No upstream `peekoff.com`, `10.25.150.x`, TrueNAS, MinIO, Backblaze B2, Bitwarden secret-store or `proxmox-csi-2` binding may enter active desired state.
- Business and catalog workloads must fit the single 6 vCPU / 32 GiB node; keep heavyweight additions staged until capacity evidence exists.

## Agent skills

Use one focused skill under `.agents/skills`:
- `argo-debug`: Argo reconciliation/runtime evidence.
- `runtime-observer`: bounded post-merge/SRE observation.
- `add-application`: onboard one application.
- `tool-discovery`: choose the smallest useful tool/MCP.
- `git-workflow`: branch/PR lifecycle.

Do not create parallel `.opencode/skills`, `.codex/skills` or duplicated prompt trees.

## Tool order

```text
repository files / deterministic render
-> focused .agents skill
-> authoritative upstream schema/docs
-> Argo MCP read-only
-> bounded Kubernetes/Talos observation only when Argo evidence is insufficient
```

Managed Omnigent runners must not receive cluster-admin, Secret-read, Proxmox, Talos-admin or broad Doppler credentials.

## Validation

For Kubernetes changes run the repository gates relevant to the change:
- `npm run check:v1-contract`
- `npm run check:post-v1-staged`
- `kustomize build --enable-helm <changed-root>`

Prefer a few high-value architecture/render gates over tests that duplicate Argo's live reconciliation checks.

Never print or commit secret values.
