---
sidebar_position: 4
title: Smadja environment porting TODO
description: Remaining bindings to resolve before the V1 clean install.
---

# Smadja environment porting TODO

The V1 no longer builds a parallel candidate cluster. The old Talos cluster is disposable: `homelab-infra` destroys it through its existing state, then `kube-ops` recreates the target directly as VMID 101 / `10.0.20.60`.

## Fixed bindings

- Proxmox host: `tatouine`.
- Proxmox API endpoint: `https://10.0.20.51:8006`.
- VMID: `101`.
- Talos node IP: `10.0.20.60/24`.
- gateway: `10.0.20.1`.
- DNS: `10.0.20.53`, then `1.1.1.1`.
- bridge: `vmbr0`, untagged.
- Talos system disk: 100 GiB on `nvme-vm`.
- application PVC datastore: `tank-vm` through Proxmox CSI.
- Talos: `v1.13.10`.
- Kubernetes: `1.36.3`.
- no Talos VIP, dedicated LB VM, worker VM or BLE proxy VM.
- GitOps repository: `SmadjaPaul/kube-ops`.
- fresh state key: `kube-ops/homeops/terraform.tfstate`.
- runtime secret provider: Doppler via `ClusterSecretStore/doppler-cluster`.
- Migadu remains the V1 SMTP/mail provider.

## Already converged in the V1 branch

- legacy media NFS PV removed from the active Argo graph and deleted;
- `media-share` is a dynamic 2 TiB `ReadWriteOnce` PVC on `proxmox-csi`; the V1 is single-node, so Jellyfin/SABnzbd may share that claim without introducing an NFS server;
- active `proxmox-csi-2` aliases removed from the media workloads touched by this migration;
- the duplicate legacy clean-install runbook is superseded by the canonical V1 agent runbook;
- `scripts/check-v1-active-contract.sh` renders active roots and fails on legacy NFS/TrueNAS/Backblaze/MinIO/Bitwarden/upstream bindings while allowing only the canonical Hetzner backup endpoint and emitting the active Doppler key-name inventory.

Run before every destructive plan:

```bash
npm run check:v1-contract
```

The command prints secret **names only**, never secret values.

## Resolve before the destructive cutover

0. **Gateway/LB binding**: prove a free `10.0.20.0/24` Cilium LB range from live UniFi/DHCP evidence, then activate the pool and bind Cloudflared to the resulting Gateway service. Do not reuse upstream `10.25.150.x`.
0. **Smart-home hardware binding**: Zigbee2MQTT and Matter Server remain disabled until the local Zigbee coordinator/BLE path is explicitly identified.

1. Run the static gates in both PRs. Fix every syntax, Kustomize, Helm or OpenTofu validation error before any live plan.
2. In `homelab-infra`, run a live `terraform/proxmox` plan against the existing OCI state. The allowed destructive delta is the legacy Talos module only: VM101, its disposable 10 TiB guest disk, Talos machine material and module-owned boot artifact if planned. Any change to `bond0`, `vmbr0`, ZFS/tank, another VM/LXC or an unrelated Proxmox object is a hard stop.
3. Verify VM101 contains no application data that must survive. This V1 intentionally has no backup/restore gate because the operator has declared the cluster disposable.
4. In `kube-ops`, create local uncommitted provider variables for Proxmox credentials and state encryption. Never copy credentials into Git.
5. Verify that `proxmox_cluster = "tatouine"` has the semantics expected by this fork. If it is only a topology label, keep it; if the provider requires another cluster identifier, use live read-only Proxmox evidence.
6. Port the active Cilium load-balancer/L2 address configuration from upstream `10.25.150.x` to a small proven-free range on `10.0.20.0/24`. Do not guess addresses and do not enable BGP for V1.
7. Remove or port every active upstream literal: `peekoff.com`, `10.25.150.*`, `host3`, `Nvme1`, `velocity`, TrueNAS addresses, upstream Cloudflare identifiers and upstream real-user identities. Disabled manifests may remain as upstream reference only if they cannot be reconciled by Argo.
8. Run `npm run check:v1-contract`. Treat its `ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN/END` output as the canonical key-name inventory. Every active store must resolve to `doppler-cluster`; every remote key must be `UPPER_SNAKE_CASE`.
9. Apply the `homelab-infra/terraform/doppler` change that creates `cluster/prd`, read-only `eso-cluster` and `infrastructure/prd:ESO_CLUSTER`.
10. Compare the emitted required key names with `cluster/prd` and the existing Doppler domains. Record only status (`READY`, `FOUND_SOURCE`, `GENERATE`, `MISSING_EXTERNAL`) and key names. Materialize only the active required names into `cluster/prd`; reuse existing values where continuity matters and generate fresh values only for disposable credentials. Do not reveal values in logs, prompts or PRs.
11. Keep Migadu SMTP keys available for Authentik: `MIGADU_SMTP_HOST`, `MIGADU_SMTP_PORT`, `MIGADU_SMTP_USER`, `MIGADU_SMTP_PASSWORD`, and `MIGADU_SMTP_FROM`.
12. Replace upstream Authentik users/groups with the Smadja taxonomy: `family`, `media`, `dev`, `data`, `iot`, `admin`, `authentik-admins`. Do not import upstream real users.
13. Prove Proxmox CSI can use `tank-vm` with the least-privilege Proxmox credentials expected by the chart.
14. Keep Velero and CNPG backup resources enabled against Hetzner Object Storage. Remove Backblaze B2, MinIO and TrueNAS from the active graph. `npm run check:v1-contract` must report zero legacy backup references and `ACTIVE_HETZNER_BACKUP_ENDPOINT=PASS`.
15. Keep the business stack disabled: Stalwart, Bulwark/jmap-webmail, TMail, La Suite Messages, Listmonk, Twenty, Chatwoot and SES. Migadu SMTP is the explicit exception.
16. Keep GPT Researcher, Pocket-TTS and Whisper enabled. Keep vLLM, Frigate and Minecraft disabled for first green.
17. Scale control-plane services and CNPG databases to one replica where extra replicas provide no physical availability on the single AOOSTAR.

## Live cutover sequence

The cutover must be sequential. Never allow both repositories to manage VMID 101 simultaneously.

1. Merge the reviewed repository-boundary/destruction PR in `homelab-infra`.
2. Re-run the live Proxmox plan.
3. With explicit operator approval, apply the legacy Talos destruction.
4. Verify VMID 101 is absent and `10.0.20.60` is free.
5. Initialize `kube-ops` against the fresh OCI state key. Do not import anything.
6. Run the `kube-ops` plan. It must create exactly the intended clean cluster substrate; unexpected destroys or unrelated external-provider resources are a hard stop.
7. Apply the Talos cluster and prove Talos, Kubernetes, Cilium and CoreDNS health using the node IP.
8. Bootstrap External Secrets and the Doppler service token.
9. Bootstrap Argo CD, then reconcile infrastructure in layers.
10. Bring CNPG and Authentik green before enabling application layers.
11. Bring personal apps, AI/media and home automation green.
12. Only then point or verify the Cloudflare wildcard tunnel/public DNS path to the new Gateway.
13. After sustained green state, implement B2/backup policy and prove one restore.

## Acceptance

V1 is complete when:

- one Talos node `homeops-01` is Ready and schedulable;
- Cilium/CoreDNS/Gateway and Proxmox CSI are healthy;
- every active `ExternalSecret` is Ready from Doppler;
- Argo CD has no unexplained OutOfSync/Degraded application;
- Authentik login works and Migadu SMTP sends a test message;
- GPT Researcher, Pocket-TTS and Whisper are deployed at one replica;
- selected personal/media/home-automation applications are healthy;
- no active resource points at upstream domains, networks, datastores or identities;
- the business stack remains deferred; CNPG and Velero backups target Hetzner Object Storage;
- the old Flux cluster no longer exists.

Do not refactor upstream architecture while executing this runbook. The target is first stable cluster, then cleanup.
