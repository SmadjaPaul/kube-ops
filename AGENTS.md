# AGENTS.md — kube-ops operating contract

## Authority

Git is the Kubernetes desired-state authority. Argo CD continuously reconciles that state. Runtime tools provide evidence; they are not a second steady-state mutation plane.

Repository boundary:

- `homelab-infra`: Proxmox host/network, VM101, Talos machine lifecycle/secrets/bootstrap, UniFi/LAN, Cloudflare account/tunnel/DNS, Doppler bootstrap, Hetzner Object Storage, Migadu, N100 host lifecycle and other external prerequisites.
- `kube-ops`: Kubernetes bootstrap and all Kubernetes/Argo desired state after the kubeconfig handoff.

This repository MUST NOT contain Terraform/OpenTofu state or providers. A real infrastructure object has exactly one IaC owner.

## Current platform contract

- one schedulable Talos control-plane node: VM101 / 10.0.20.60, created by `homelab-infra`;
- Talos 1.13.10 / Kubernetes 1.36.3;
- Cilium with kube-proxy replacement and Gateway API;
- Argo CD is the only steady-state Kubernetes reconciler;
- Longhorn is the V1 application storage layer with `longhorn-fast` and `longhorn-bulk`;
- Proxmox CSI is compatibility/staged only and is not the default storage path;
- no TrueNAS/NFS dependency for the active V1 platform;
- CNPG one instance per application for V1;
- CNPG/Barman and Velero/Kopia backups target Hetzner Object Storage;
- Doppler is the external/bootstrap secret authority; ESO is the runtime delivery path;
- Authentik is the OIDC authority;
- Migadu remains SMTP;
- the AOOSTAR has no discrete GPU; GPU-only workloads stay disabled/staged unless hardware changes;
- public exposure is `*.smadja.dev -> Cloudflare Tunnel -> in-cluster cloudflared -> Cilium Gateway/external -> HTTPRoute`.

## Local-first post-V1 target

Self-hosted user-facing applications should remain usable from the LAN during WAN loss.

The target path is:

- `Gateway/internal` with a stable LAN-reachable Cilium LoadBalancer address;
- private ExternalDNS derives application records from routes attached to `Gateway/internal`;
- private records are synchronized into UniFi DNS;
- Cloudflare remains the optional remote path through `Gateway/external`;
- AdGuard remains filtering/cache, not a second application registry.

Do not remove an existing external route until the replacement LAN path is proven.

## Bootstrap exception

`scripts/bootstrap-cluster.sh` is the supported direct Kubernetes bootstrap path. After Argo is running, normal mutations are Git -> Argo -> Kubernetes.

Direct `kubectl` is allowed for diagnostics and bounded bootstrap/recovery evidence only. Do not create durable configuration outside Git.

## Forbidden legacy bindings

Active state must not contain:

- `theepicsaxguy/homelab` as desired-state source;
- `peekoff.com`;
- `10.25.150.x`;
- TrueNAS/NFS media dependencies;
- MinIO or Backblaze B2 backup targets;
- Bitwarden secret-store bindings;
- a second OpenTofu/Terraform tree in this repository.

## Validation

Run `npm run check:v1-contract` for Kubernetes desired-state changes and the relevant repository checks for the changed scope.

A live bootstrap, destructive infrastructure action, PKI/secret rotation, storage deletion, or cluster reconstruction requires explicit operator approval.
