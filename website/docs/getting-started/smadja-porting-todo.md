---
sidebar_position: 4
title: Smadja environment porting TODO
description: Unknown environment bindings to resolve before the first OpenTofu plan.
---

# Smadja environment porting TODO

This fork is intentionally being ported with the smallest possible delta from upstream. Known values from the existing Smadja infrastructure have been applied. Values that cannot be proven from the existing repositories are listed here instead of being guessed.

## Known bindings already applied

- Proxmox node and cluster: `tatouine`.
- Proxmox API endpoint: `https://10.0.20.51:8006`.
- LAN: `10.0.20.0/24`.
- LAN gateway: `10.0.20.1`.
- DNS: `10.0.20.53`, with `1.1.1.1` as secondary.
- Proxmox bridge: `vmbr0`.
- Primary domain: `smadja.dev`.
- Authentik public endpoint: `auth.smadja.dev`.
- Proxmox VM datastore used by the existing Talos data disk: `tank-vm`.
- Proxmox ISO/image datastore: `tank-iso`.
- Argo CD repository: `SmadjaPaul/kube-ops`.
- Upstream LB and BLE proxy definitions are disabled until local addresses are allocated.

## Resolve before tofu plan

1. Allocate a collision-free Kubernetes VIP and API load-balancer VIP on `10.0.20.0/24`. Replace `TODO_LAN_VIP` and `TODO_API_LB_VIP` in `tofu/config.auto.tfvars`.
2. Decide the initial Talos topology for the 64 GB AOOSTAR host. Rewrite `tofu/nodes.auto.tfvars`; all upstream `10.25.150.x` addresses, MAC addresses, VM IDs, and the `velocity` datastore belong to the upstream author's environment and must not be deployed.
3. Confirm whether a dedicated pair of load-balancer VMs is required. It is disabled for the first port because the current Smadja environment has no proven free VM IDs, MAC addresses, or reserved addresses for those VMs.
4. Confirm whether the Matter BLE proxy is required. It is disabled because the upstream USB device and address are not part of the Smadja hardware inventory.
5. Create a local `tofu/terraform.tfvars` from the example. Use Proxmox endpoint `https://10.0.20.51:8006`, node/cluster `tatouine`, and credentials from the existing secret authority. Never commit the token.
6. Resolve the upstream Bitwarden Secrets Manager dependency. The current Smadja authority is Doppler for external/bootstrap/recovery and SOPS/age for cluster-owned static secrets. For the first upstream boot, either provide Bitwarden exactly as upstream expects or make a separately reviewed minimal ESO backend adaptation. Do not silently redesign secrets in this porting PR.
7. Configure the state encryption passphrase and initialize the NEW `kube-ops/homeops-v2/terraform.tfstate` key in the existing OCI Object Storage bucket. This is fresh cluster state: no `terraform state mv`, import, backend migration, or reuse of any `homelab-infra` state is allowed.
8. Replace remaining upstream environment literals throughout Kubernetes manifests: `peekoff.com`, `10.25.150.0/24`, `host3`, `Nvme1`, `velocity`, TrueNAS/NFS endpoints, Cloudflare tunnel identity, Backblaze B2/MinIO identities, and upstream Authentik users/groups. Verify each occurrence semantically rather than using a blind replacement for addresses.
9. Keep Cloudflare, UniFi, AdGuard, Doppler bootstrap, Migadu and all other infrastructure external to the candidate cluster in `SmadjaPaul/homelab-infra`. `kube-ops` may consume the resulting endpoints/tokens but must not provision duplicate external resources. Do not alter current production DNS or tunnel routes until the candidate cluster is healthy.
10. Reconcile Authentik groups with the Smadja baseline: `family`, `media`, `dev`, `data`, `iot`, `admin`, and `authentik-admins`. Do not import upstream real users.
11. Audit the application catalog before first Argo sync. V1 intentionally disables the business stack, including `jmap-webmail`, TMail/Auth mail integration, outbound SMTP, future Stalwart/Bulwark/Listmonk/Twenty/Chatwoot/SES components, and any other business-only workload. Hardware-dependent or expensive workloads remain disabled where not proven. Personal/family services stay in scope.
12. Confirm Proxmox CSI can create volumes on `tank-vm` and create the least-privilege CSI account expected by the upstream bootstrap.
13. Determine migration separately for data currently stored on the existing 10 TiB Talos disk. Do not attach, format, delete, or repurpose that disk during candidate-cluster bootstrap.

## Local-agent acceptance gate

Before any apply, the local agent must prove:

- no unresolved `TODO_*` value is consumed by OpenTofu;
- no active Talos node uses an upstream IP, MAC address, VM ID, node name, or datastore;
- no active route or certificate targets `peekoff.com`;
- `tofu fmt` and `tofu validate` pass;
- the OpenTofu plan contains no destroy or mutation of existing Smadja Proxmox resources;
- the candidate uses new VM IDs and collision-free LAN addresses;
- no secret is committed;
- the `kube-ops` OpenTofu plan contains only candidate-cluster resources and does not manage Cloudflare, UniFi, AdGuard, Migadu, Doppler bootstrap or other external provider resources;
- no Cloudflare production route is changed by the infrastructure plan;
- the existing Flux cluster and its 10 TiB data disk remain untouched.

Stop on any destructive or ambiguous plan. The next step after this document is resolution of these environment bindings, not refactoring upstream architecture.
