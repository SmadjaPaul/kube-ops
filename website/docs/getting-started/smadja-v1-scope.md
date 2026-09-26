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
- dedicated load-balancer VMs disabled;
- BGP disabled for first boot; use the upstream Cilium L2/Gateway path;
- one free Talos VIP must be proven on `10.0.20.0/24` before apply;
- workloads are allowed on the control plane.

## Secrets

V1 uses Doppler, not Bitwarden Secrets Manager.

- External Secrets Operator uses a Doppler-backed compatibility `ClusterSecretStore` named `bitwarden-backend` to minimize the fork delta.
- `homelab-infra/terraform/doppler` creates `cluster/prd` and the read-only `eso-cluster` token; its bootstrap reference is `infrastructure/prd:ESO_CLUSTER`.
- The migration agent materializes the remote key names expected by active upstream `ExternalSecret` objects into `cluster/prd`, reusing existing values where appropriate and generating disposable application secrets where no prior identity matters.
- Secret values must never be printed, committed, copied into prompts or persisted in local files.

## Enabled

- Talos 1.13.9 + Kubernetes 1.36.3;
- Cilium, Gateway API, Argo CD, cert-manager, External Secrets, Proxmox CSI, CNPG and the useful upstream security/observability baseline;
- Authentik as central identity;
- Migadu retained only as the existing hosted mail/SMTP transport;
- Home Assistant, MQTT, Zigbee2MQTT and Matter Server;
- Immich and the media/personal applications selected from upstream;
- OpenWebUI, LiteLLM, OpenCode, OpenClaw, Qdrant, GPT Researcher, Pocket-TTS and Whisper ASR;
- single replicas wherever HA has no value on one physical node.

## Deferred or disabled for first stable cluster

- Stalwart, Bulwark/jmap-webmail, TMail, La Suite Messages, Listmonk, Twenty, Chatwoot, SES and the rest of the business stack;
- Kubernetes UniFi Network Application because the UGC Fiber already provides UniFi Network;
- Frigate until camera configuration exists;
- Minecraft;
- vLLM local embedding workload until dedicated compute justifies it;
- legacy TrueNAS/MinIO backup assumptions and any upstream backup target that has not been ported;
- adding new applications that are not already required for the first stable cluster.

## Stability rule

Bootstrap in layers: Talos/Cilium/CoreDNS -> CSI/controllers -> ESO/Doppler -> Argo -> Authentik/CNPG -> personal apps -> AI/media/home automation -> public edge. Do not enable the next layer while the current one is unhealthy.

Backup/DR is the first post-green hardening step: configure the selected offsite target and prove one restore after the cluster is stable.
