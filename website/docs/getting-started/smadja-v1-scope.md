---
sidebar_position: 5
title: Smadja V1 scope
description: Fast clean-install scope for the first stable cluster.
---

# Smadja V1 scope

V1 is a clean replacement of the existing Talos/Flux cluster. There is no application data to migrate and no pre-cutover backup/restore requirement. The objective is the shortest path to one stable single-node cluster.

## Ownership

- `SmadjaPaul/homelab-infra` keeps physical/external infrastructure: Proxmox host/network, UniFi, AdGuard, Cloudflare account/tunnel/DNS authority, Doppler, OCI and Migadu.
- Its existing Proxmox state is used to destroy the legacy Talos VM and disposable 10 TiB virtual data disk during the reviewed cutover.
- `SmadjaPaul/kube-ops` then recreates VMID 101 / `10.0.20.60` from a fresh state key `kube-ops/homeops/terraform.tfstate`.
- No Terraform/OpenTofu state is moved, imported or migrated between repositories.

## V1 topology

- one schedulable Talos control-plane VM on `tatouine`;
- VMID `101`, IP `10.0.20.60`, 6 vCPU, 32 GiB RAM, 100 GiB system disk on `nvme-vm`;
- Proxmox CSI dynamically provisions application volumes on `tank-vm`;
- no legacy 10 TiB guest disk;
- no Talos VIP and no dedicated load-balancer VMs in V1;
- no BGP for first boot; use the existing upstream Cilium L2/Gateway path once the local load-balancer address pool is ported;
- workloads are allowed on the control plane;
- Talos/Kubernetes bootstrap uses the control-plane IP directly and does not depend on public DNS being live.

## Versions

- Talos `v1.13.10`;
- Kubernetes `1.36.3`.

The V1 deliberately stays on the patched Talos 1.13 line rather than combining the architecture migration with a Talos 1.14 minor upgrade.

## Secrets

V1 uses Doppler, not Bitwarden Secrets Manager.

- External Secrets Operator uses `ClusterSecretStore/doppler-cluster`.
- `homelab-infra/terraform/doppler` owns a temporary compatibility runtime domain `cluster/prd` and read-only service token `eso-cluster`; the operator-only bootstrap reference is `infrastructure/prd:ESO_CLUSTER`.
- Active `ExternalSecret.remoteRef.key` values use Doppler-safe `UPPER_SNAKE_CASE`.
- The migration agent inventories only active secret references, then materializes those names into `cluster/prd` from existing Doppler domains or generates new disposable application credentials where appropriate.
- Secret values must never be printed, committed, copied into prompts or persisted in repository files.

## Enabled

- Cilium, Gateway API, Argo CD, cert-manager, External Secrets, Proxmox CSI, CNPG and the useful upstream security/observability baseline;
- Authentik as central identity;
- Migadu retained as hosted mail and SMTP transport, including Authentik outbound mail;
- Home Assistant, MQTT, Zigbee2MQTT and Matter Server;
- Immich and the selected media/personal applications;
- OpenWebUI, LiteLLM, OpenCode, OpenClaw, Qdrant, GPT Researcher, Pocket-TTS and Whisper ASR;
- one replica wherever extra replicas provide no useful availability on the single physical host;
- Hetzner Object Storage in `fsn1` as the single V1 offsite S3 backend;
- continuous CNPG WAL archiving plus weekly base backups with a 14-day recovery window;
- Velero/Kopia daily filesystem backups for enabled stateful workloads with 14-day TTL.

## Deferred or disabled for first green cluster

- Stalwart, Bulwark/jmap-webmail, TMail, La Suite Messages, Listmonk, Twenty, Chatwoot, SES and the rest of the business stack;
- Kubernetes UniFi Network Application because the UGC Fiber already provides UniFi Network;
- Frigate until camera configuration exists;
- Minecraft;
- vLLM local embedding workload until dedicated compute justifies it;
- adding new applications that are not required for the first stable cluster.

## Stability rule

Bootstrap in layers:

```text
legacy cluster destroy
  -> Talos / Cilium / CoreDNS
  -> Proxmox CSI / core controllers
  -> ESO / Doppler
  -> Argo CD
  -> CNPG / Authentik
  -> personal applications
  -> AI / media / home automation
  -> CNPG WAL + Velero backups to Hetzner
  -> Cloudflare public edge
  -> restore proof
```

Do not enable the next layer while the current layer is unhealthy. Backup resources are part of V1 desired state; restore proof remains the durability gate after first green.
