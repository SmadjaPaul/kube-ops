---
sidebar_position: 6
title: Smadja clean-install migration runbook
description: Execution contract for the AI/operator performing the V1 cluster replacement.
---

# Smadja clean-install migration runbook

> Audience: the AI/operator executing the migration. This document is prescriptive. Prefer the shortest upstream path and stop on unexplained drift.

## Mission

Replace the current disposable Talos/Flux cluster with the `SmadjaPaul/kube-ops` single-node Argo-based distribution. There is no application data or backup to migrate. External infrastructure remains in `SmadjaPaul/homelab-infra`.

Success means a stable cluster, not maximum application count on the first sync.

## Hard boundaries

1. Do not migrate Terraform/OpenTofu state between repositories.
2. Do not mutate `bond0`, `vmbr0`, the ZFS pool, UniFi, AdGuard, Cloudflare, Migadu or OCI state as a side effect of the cluster replacement.
3. Do not adopt Bitwarden. Use the Doppler ESO provider already used by the previous platform.
4. Do not introduce Stalwart/Bulwark/Listmonk/Twenty/Chatwoot/SES during V1.
5. Keep Migadu available as SMTP for Authentik/application mail.
6. Keep GPT Researcher, Pocket-TTS and Whisper ASR enabled.
7. Keep Home Assistant, MQTT, Zigbee2MQTT and Matter Server in scope.
8. Keep Frigate, Minecraft, vLLM and the Kubernetes UniFi application disabled.
9. No secret values in Git, logs, plans, reports or chat output.

## Phase 0 - prove the destructive premise

Before any mutation, collect read-only evidence:

```bash
qm status 101
qm config 101
zpool list
zfs list
```

Confirm the operator's declared premise: the old Kubernetes cluster contains no application data that must be preserved, and the old 10 TiB guest disk is disposable. Do not create a migration/backup project for empty data.

Run static checks in both repositories. Stop on unrelated dirty work.

## Phase 1 - prepare Doppler before destroying Kubernetes

`homelab-infra/terraform/doppler` must contain the `cluster` runtime domain:

```text
project: cluster
config:  prd
token:   eso-cluster (read-only)
bootstrap reference: infrastructure/prd:ESO_CLUSTER
```

Plan/apply only that existing Doppler root using its current backend. This is an additive change, not a state migration.

Then inventory every active upstream secret reference without reading values:

```bash
rg -n 'remoteRef:|key:' k8s --glob '*.yaml'
rg -n 'bitwarden-backend' k8s --glob '*.yaml'
```

Build a key-name inventory for active manifests. Compare names against existing Doppler projects (`edge/prd`, `identity/prd`, `apps/prd`, `storage/prd`, `crypto/prd`) without printing values.

For the fastest V1, materialize the exact key names expected by active upstream manifests into `cluster/prd`. Reuse existing values through a non-logging pipe where identity/credentials must remain stable; generate fresh random values for disposable application secrets. Do not paste values into shell arguments that are saved in history.

The cluster gets only the read-only `ESO_CLUSTER` service token. Doppler documents Service Tokens as config-scoped and recommended for External Secrets Operator.

## Phase 2 - retire the old cluster in homelab-infra

Use PR `SmadjaPaul/homelab-infra#54`.

Run the live Proxmox plan against the existing `proxmox/terraform.tfstate` backend. Expected destructive scope is the legacy Talos module only: VM101, its boot/root resources, its disposable 10 TiB virtual data disk, and Talos bootstrap state owned by that module.

Hard stop if the plan changes or destroys any of:

- `proxmox_network_linux_bond.bond0`;
- `proxmox_network_linux_bridge.vmbr0`;
- unrelated VM/LXC resources;
- ZFS pool/datasets outside the VM's managed virtual disks;
- Cloudflare, UniFi, Migadu, Doppler or OCI resources.

Apply the destructive plan only after it exactly matches the reviewed scope. Verify VMID 101 and `10.0.20.60` are free before proceeding.

## Phase 3 - finalize kube-ops environment bindings

Target topology is already encoded:

```text
node:       homeops-01
host:       tatouine
VMID:       101
IP:         10.0.20.60/24
gateway:    10.0.20.1
DNS:        10.0.20.53, 1.1.1.1
CPU:        6
RAM:        32 GiB
root disk:  100 GiB on nvme-vm
PVC store:  tank-vm via Proxmox CSI
Talos:      1.13.9
Kubernetes: 1.36.3
```

Proxmox generates the VM MAC address. Do not invent or reserve one unless runtime evidence requires it.

Allocate exactly one free Talos VIP on `10.0.20.0/24`. Prove availability using UniFi reservations/client state plus LAN probes; do not guess. Put it in `tofu/config.auto.tfvars`. `api_lb_vip` stays empty and dedicated LB VMs stay disabled.

## Phase 4 - port active upstream manifests before first Argo sync

Run exhaustive checks:

```bash
rg -n 'peekoff\.com|10\.25\.150\.|host3|Nvme1|velocity|truenas|proxmox-csi-2' k8s tofu
rg -n 'bitwarden|Bitwarden' k8s tofu --glob '!website/**'
```

Resolve every ACTIVE occurrence semantically. Documentation/history may retain upstream references when clearly marked.

Required outcomes:

- all active hostnames use `smadja.dev`;
- no active upstream LAN/IP/datastore remains;
- all PVCs use `proxmox-csi` unless a manifest has a proven reason not to;
- remove/disable upstream TrueNAS/NFS/MinIO dependencies that do not exist here;
- backup plugins/ObjectStores referencing upstream storage are disabled until post-green backup activation;
- Kubernetes UniFi stays inactive;
- Authentik groups/users are ported to the Smadja taxonomy rather than upstream identities;
- Cloudflare tunnel/runtime secrets use the existing Smadja external edge;
- Migadu SMTP keys are sourced from Doppler.

### Single-node replica policy

Use one replica/instance unless multiple pods are functionally different roles. The V1 branch already scales CoreDNS, CNPG operator, Gatekeeper, Authentik PostgreSQL and Immich PostgreSQL to one. Verify no accidental 2/3-replica application remains.

Do not scale down DaemonSets merely because there is one node.

## Phase 5 - validate before apply

Initialize `kube-ops` with the fresh OCI state key:

```text
kube-ops/homeops/terraform.tfstate
```

Never use `-migrate-state` and never import old VM101.

Inject credentials through the operator environment, including the read-only `ESO_CLUSTER` token as `TF_VAR_doppler_token`. Do not commit a populated tfvars file.

Required gates:

```bash
tofu fmt -check -recursive
tofu validate
kustomize build --enable-helm <each active root>
```

The first `tofu plan` must describe a fresh VM101 and bootstrap resources only. Stop if it references old state, proposes unrelated external infrastructure changes, or contains stale upstream addresses.

## Phase 6 - create and bootstrap

Apply the reviewed `kube-ops` plan, then verify in this order:

1. Talos health and Kubernetes API;
2. Cilium and CoreDNS;
3. Proxmox CSI and one disposable PVC smoke test;
4. cert-manager and External Secrets Operator;
5. `ClusterSecretStore/bitwarden-backend` reports Ready even though its provider is Doppler;
6. Argo CD;
7. CNPG single-instance databases;
8. Authentik and OIDC.

Do not cut public traffic to applications before these are green.

## Phase 7 - sync applications in bounded groups

Bring up groups in this order so failures remain attributable:

1. personal knowledge/tools;
2. Immich/media;
3. Home Assistant + MQTT + Zigbee2MQTT + Matter;
4. OpenWebUI/LiteLLM/Qdrant/OpenCode/OpenClaw;
5. GPT Researcher, Pocket-TTS and Whisper ASR.

Keep `jmap-webmail`, Frigate, Minecraft, vLLM and the future business stack inactive.

## Phase 8 - edge cutover

Only after LAN/internal service health is proven, adapt the existing Cloudflare tunnel/DNS contract in `homelab-infra` if required. Do not create a second tunnel or duplicate public DNS authority in `kube-ops`.

Verify representative paths:

```text
browser -> Cloudflare -> tunnel -> Cilium Gateway -> Authentik/app
LAN/VPN -> internal Gateway -> private/admin app
```

## First-green acceptance

V1 is green when:

- `homeops-01` is Ready and schedulable;
- Cilium/Hubble/CoreDNS are healthy;
- dynamic Proxmox CSI PVC creation works on `tank-vm`;
- active ESO secrets reconcile from Doppler;
- Argo has no unexplained Degraded/OutOfSync applications;
- Authentik login and group claims work;
- a test email leaves Authentik through Migadu SMTP;
- Immich, Jellyfin/selected media, Trilium/selected personal apps and Home Assistant are reachable;
- GPT Researcher, Pocket-TTS and Whisper health endpoints are functional;
- no active manifest depends on upstream `peekoff.com`, TrueNAS or Bitwarden.

## Immediately after green

Backup/DR becomes the next task, not a prerequisite to replacing an empty cluster. Configure the chosen offsite target, back up the first real data, and prove one restore before the platform starts accumulating irreplaceable data.

Do not expand into the business V2 until the V1 cluster has remained operational through normal reconciles/reboots and the restore path is proven.
