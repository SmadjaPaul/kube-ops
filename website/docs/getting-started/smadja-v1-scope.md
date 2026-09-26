---
sidebar_position: 5
title: Smadja V1 scope
description: First deployment scope and explicit deferrals.
---

# Smadja V1 scope

V1 proves the personal/family platform on the new `homeops-v2` candidate cluster before any business stack is introduced.

## Repository ownership

- `SmadjaPaul/kube-ops` owns only the NEW candidate Talos/Proxmox cluster resources required by the upstream distribution, plus Kubernetes desired state.
- `SmadjaPaul/homelab-infra` keeps all existing Terraform/OpenTofu roots for Cloudflare, UniFi, AdGuard, Doppler bootstrap, OCI external infrastructure, Migadu and the existing production Talos VM/state.
- The candidate cluster uses the fresh OCI state key `kube-ops/homeops-v2/terraform.tfstate`. No existing state is migrated.
- Existing VM101 / `10.0.20.60` and its 10 TiB disk remain untouched until an explicit cutover/migration phase.

## Enabled V1 capability classes

- Talos + Kubernetes + Cilium + Argo CD.
- Proxmox CSI, CNPG, cert-manager, External Secrets and the upstream security/observability baseline.
- Authentik without SMTP as the central identity provider.
- Personal/family applications that do not require business mail, payment, CRM or marketing infrastructure.
- Home Assistant, MQTT, Zigbee2MQTT and Matter remain in the desired catalog; hardware-dependent activation is gated by real device configuration.
- Immich/media/personal knowledge and the useful upstream AI applications may be enabled as resource capacity permits.

## Explicitly deferred

The following are not prerequisites for V1 and must not block first deployment:

- Stalwart, Bulwark/jmap-webmail, TMail and La Suite Messages.
- SES, Cloudflare Email Service, Migadu integration into Kubernetes and outbound Authentik SMTP.
- Listmonk, Twenty, Chatwoot, e-commerce backend, billing/accounting and e-signature.
- Any marketing, CRM, support or other business-only stack.
- Destructive migration of the existing Flux cluster or its storage.

Their manifests may remain in Git as dormant future work, but they must not appear in active Kustomizations, Argo Applications, bootstrap secrets or required infrastructure plans.

## First-deployment gate

V1 is ready for apply only when:

1. all active upstream IPs, VM IDs, MAC addresses, datastores and `peekoff.com` literals are gone;
2. the single-node candidate topology and collision-free LAN addresses are proven;
3. the candidate state initializes under the fresh OCI key with no migration;
4. `tofu fmt`, `tofu validate` and the repository static checks pass;
5. the OpenTofu plan contains no mutation or destroy of existing Smadja resources;
6. no active Kubernetes manifest requires the deferred business mail stack;
7. external infrastructure changes, if any, are reviewed separately in `homelab-infra`.
