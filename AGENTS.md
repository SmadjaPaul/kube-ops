# AGENTS.md — kube-ops operating contract

## Authority

Git is the Kubernetes desired-state authority. Argo CD continuously reconciles that state. Runtime tools provide evidence; they are not a second steady-state mutation plane.

Repository boundary:
- `homelab-infra`: Proxmox host/network, VM101, Talos machine lifecycle/secrets/bootstrap, UniFi/LAN, Cloudflare account/tunnel/DNS, Doppler bootstrap, Hetzner Object Storage, Migadu and other external prerequisites.
- `kube-ops`: Kubernetes bootstrap and all Kubernetes/Argo desired state after the kubeconfig handoff.

This repository MUST NOT contain Terraform/OpenTofu state or providers. A real infrastructure object has exactly one IaC owner.

## V1 deployment contract

- one schedulable Talos control-plane node: VM101 / 10.0.20.60, created by `homelab-infra`;
- Talos 1.13.10 / Kubernetes 1.36.3;
- Gateway API v1.6.1 CRDs before Cilium;
- Cilium 1.20.2, kube-proxy replacement, Talos KubePrism localhost:7445;
- Argo CD is the only steady-state Kubernetes reconciler;
- Proxmox CSI chart 0.5.12 / plugin v0.20.0, with credentials delivered by ESO;
- Proxmox CSI topology is region `homeops`, zone `tatouine`;
- RWO/single-node storage from Proxmox `tank-vm`; no TrueNAS/NFS dependency;
- CNPG one instance per application for V1;
- CNPG Barman + Velero/Kopia backups target Hetzner Object Storage;
- Doppler is the external/bootstrap secret authority; ESO is the runtime delivery path;
- Authentik is the OIDC authority;
- Migadu remains SMTP;
- GPT Researcher, Pocket-TTS and Whisper remain in V1;
- vLLM, Frigate, Minecraft, security hardening stack and business stack remain post-V1;
- public exposure is `*.smadja.dev -> Cloudflare Tunnel -> in-cluster cloudflared -> Cilium Gateway -> HTTPRoute`.

## Bootstrap exception

`scripts/bootstrap-cluster.sh` is the only supported direct Kubernetes bootstrap path. It installs the CRDs/controllers required for GitOps, seeds one Doppler service token Secret, installs Argo CD, then applies only the AppProjects/ApplicationSets from Git.

After Argo is running, normal mutations are Git -> Argo -> Kubernetes. Do not add a second bootstrap implementation.

## Forbidden legacy bindings

Active V1 state must not contain:
- `theepicsaxguy/homelab`;
- `peekoff.com`;
- `10.25.150.x`;
- TrueNAS/NFS media dependencies;
- MinIO or Backblaze B2 backup targets;
- Bitwarden secret-store bindings;
- `proxmox-csi-2`.

## Validation

Run `npm run check:v1-contract` for every Kubernetes change. It renders every first-green Kustomize root with Helm enabled and rejects repository-boundary drift and legacy bindings.

A live bootstrap or destructive infrastructure action always requires explicit operator approval.
