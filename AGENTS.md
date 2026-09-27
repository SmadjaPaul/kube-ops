# AGENTS.md — kube-ops operating contract

## Authority

Git is the Kubernetes desired-state authority. Argo CD continuously reconciles that state. Runtime tools provide evidence; they are not a second mutation plane.

Repository boundary:
- `homelab-infra`: Proxmox host/network, VM101 / 10.0.20.60, Talos image/config/secrets/bootstrap, UniFi/LAN, Cloudflare, Doppler bootstrap, Hetzner Object Storage, Migadu and other external infrastructure.
- `kube-ops`: Kubernetes bootstrap and all Kubernetes/Argo desired state after the kubeconfig handoff.

No Terraform/OpenTofu state belongs in this repository. A real infrastructure object must never have a second owner here.

## V1 deployment contract

- `main` must bootstrap from a fresh Talos/Kubernetes cluster in one documented path.
- V1 is one schedulable Talos control-plane node created by `homelab-infra`.
- Talos is v1.13.10 and Kubernetes is 1.36.3.
- Bootstrap order is Gateway API CRDs -> Cilium -> ESO/Doppler token -> cert-manager -> Argo CD -> root ApplicationSets.
- The bootstrap script is the only imperative Kubernetes exception; after it completes, Argo CD owns steady state.
- `proxmox-csi` backed by `tank-vm` is the canonical StorageClass.
- Proxmox CSI API identity is external infrastructure and is created by `homelab-infra`; ESO delivers the scoped token.
- V1 is single-node/RWO. Do not introduce RWX/NFS/TrueNAS assumptions.
- CNPG uses one instance per application for V1; HA requires a later multi-node topology.
- CNPG durability is Barman Cloud -> Hetzner Object Storage.
- Velero/Kopia -> Hetzner protects non-database persistent data.
- Doppler is the external/bootstrap secret authority; ESO delivers runtime secrets through `ClusterSecretStore/doppler-cluster`.
- Authentik is the OIDC authority.
- Migadu remains SMTP for V1.
- GPT Researcher, Pocket-TTS and Whisper remain in V1.
- vLLM, Frigate, Minecraft and the business stack stay outside first green.
- Public subdomains use `*.smadja.dev -> Cloudflare Tunnel -> external Gateway -> HTTPRoute`.

## Forbidden legacy bindings

Active desired state must not contain `theepicsaxguy/homelab`, `peekoff.com`, `10.25.150.x`, TrueNAS/NFS media dependencies, MinIO/Backblaze backup targets, Bitwarden secret stores or `proxmox-csi-2`.

## Workflow

```text
inspect -> isolated branch -> smallest change -> render/validate -> PR -> review -> merge -> Argo -> runtime proof
```

For Kubernetes changes run `npm run check:v1-contract` and render changed roots with `kustomize build --enable-helm`. Keep pinned versions, explicit resources/security contexts and Cilium default-deny application policies.

Never print or commit secrets. Never add Terraform/OpenTofu, Kubernetes-provider IaC or Helm-provider IaC to this repository.
