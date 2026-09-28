---
sidebar_position: 6
title: Smadja cluster deployment runbook
description: Canonical handoff from homelab-infra to kube-ops for the clean single-node cluster.
---

# Smadja cluster deployment runbook

This is the canonical deployment contract.

## Ownership

`SmadjaPaul/homelab-infra` owns the substrate and external prerequisites:

- Proxmox network and VM101;
- Talos machine lifecycle/secrets;
- Proxmox CSI API principal;
- UniFi and AdGuard;
- Cloudflare account/DNS/Tunnel;
- Doppler projects/configs/bootstrap tokens;
- Hetzner Object Storage;
- Migadu.

`SmadjaPaul/kube-ops` begins at a reachable Kubernetes API and owns Kubernetes desired state.

There is no Talos/Proxmox OpenTofu state in `kube-ops`.

## Target

```text
host: tatouine
vm: homeops-01
vmid: 101
ip: 10.0.20.60/24
gateway: 10.0.20.1
dns: 10.0.20.53, 1.1.1.1
cpu: 6
ram: 32 GiB
root: 100 GiB on nvme-vm
Talos: 1.13.10
Kubernetes: 1.36.3
PVCs: Proxmox CSI -> tank-vm
```

No worker VM, Talos VIP, dedicated LB VM, old 10 TiB guest disk or BGP bootstrap is required.

## Hard stops

Do not mutate live infrastructure when:

- the reviewed Proxmox plan changes `bond0`, `vmbr0`, storage pools or unrelated VMs/LXCs;
- VM101 contains data the operator wants to preserve;
- the required external credentials are unavailable;
- static desired-state validation is red;
- a secret value would need to be printed or committed;
- the plan introduces a second owner for Talos, Proxmox CSI identity or Cloudflare edge.

## 1. Merge/static gate

Before the live window:

```bash
npm run check:v1-contract
npm run check:post-v1-staged
```

Required properties:

```text
ACTIVE_NFS_REFERENCES=0
ACTIVE_TRUENAS_REFERENCES=0
ACTIVE_MINIO_S3_BACKUP_REFERENCES=0
ACTIVE_BACKBLAZE_REFERENCES=0
ACTIVE_BITWARDEN_REFERENCES=0
ACTIVE_HETZNER_BACKUP_ENDPOINT=PASS
ACTIVE_DOPPLER_STORES=PASS
```

No active manifest may contain a direct application `LoadBalancer` or `NodePort`.

## 2. External prerequisites in homelab-infra

From a LAN-capable trusted checkout:

1. authenticate Doppler without displaying values;
2. run the repository-native checks;
3. plan/apply the Doppler root so `cluster/prd` and `ESO_CLUSTER` are ready;
4. create/verify Hetzner Object Storage and its S3 credentials;
5. plan Cloudflare and verify the wildcard Tunnel contract;
6. create/verify the Proxmox CSI identity.

The compatibility bridge copies existing legacy runtime-domain values into `cluster/prd` using the canonical uppercase names. Internal clean-cluster OIDC credentials are generated there when continuity is unnecessary.

Continuity-sensitive external values must be preserved, notably Omnigent GitHub Connect and external provider credentials.

## 3. Review the destructive Proxmox plan

Use `homelab-infra`:

```bash
mise exec -- just plan proxmox
```

The plan must replace the disposable Talos VM101/machine secrets as intended and must not change unrelated infrastructure.

Only an explicitly reviewed saved plan may be applied.

## 4. Create the Talos/Kubernetes substrate

After approval, apply the reviewed `homelab-infra` Proxmox plan.

Acceptance before handoff:

- VM101 is `homeops-01` at `10.0.20.60`;
- Talos API is healthy;
- Kubernetes API answers on `10.0.20.60:6443`;
- the control-plane node exists;
- no second VM/substrate owner exists.

Materialize the sensitive kubeconfig/talosconfig to operator-chosen protected paths. Do not commit them.

## 5. Bootstrap Kubernetes desired state

On the same trusted LAN-capable workstation:

```bash
export KUBECONFIG=/protected/path/kubeconfig
export DOPPLER_CLUSTER_TOKEN='<read-only cluster/prd token>'
bash scripts/bootstrap-kubernetes.sh
```

The script performs only the unavoidable bootstrap:

```text
Gateway API v1.4.1 CRDs
-> Cilium 1.19.4
-> cert-manager
-> External Secrets
-> ClusterSecretStore/doppler-cluster
-> Argo CD
-> infrastructure + application ApplicationSets
```

After the ApplicationSets are created, Argo is the only steady-state Kubernetes mutation path.

## 6. First-green checks

### Networking

Verify:

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get gateway -A
kubectl get httproute -A
```

Cilium and CoreDNS must be healthy before debugging applications.

A LAN LoadBalancer IP is not required for the Cloudflare path: in-cluster cloudflared reaches the generated Cilium Gateway Service by cluster DNS.

### Secrets

Verify:

```bash
kubectl get clustersecretstore doppler-cluster
kubectl get externalsecret -A
```

Every ExternalSecret required by an active workload must become Ready.

### Storage

Verify `proxmox-csi` exists and targets `tank-vm`, then create a small throwaway PVC/pod write-read smoke test.

### Argo

Every application intended to be active must be either `Healthy/Synced` or have a documented expected bootstrap transition. No unexplained degradation is accepted.

## 7. Identity

Authentik's Smadja user/group baseline is already part of desired state.

Acceptance:

- Authentik DB/server/worker Ready;
- `https://auth.smadja.dev` works after edge activation;
- login works for the configured V1 users;
- OIDC discovery works;
- group claims work;
- Migadu SMTP sends a test message.

## 8. Edge

The external edge is owned by `homelab-infra`:

```text
*.smadja.dev
-> Cloudflare Tunnel
-> cloudflared in Kubernetes
-> https://cilium-gateway-external.gateway.svc.cluster.local:443
-> Gateway/gateway/external
-> HTTPRoute
```

Normal new subdomain exposure needs only an HTTPRoute. Do not add per-app Tunnel ingress rules or DNS records.

The bare apex `smadja.dev` is a separate contract and is not matched by `*.smadja.dev`.

## 9. Backup

Verify:

- CNPG ObjectStores reach Hetzner;
- WAL archiving progresses;
- Velero default BackupStorageLocation is Available;
- one small Velero backup/restore succeeds;
- one disposable CNPG restore/PITR succeeds.

Backup is not considered proven merely because objects exist in the bucket.

## 10. Capacity/staged applications

The node is 6 vCPU / 32 GiB. Active applications are intentionally smaller than the full repository catalogue.

KEDA is installed and Pocket-TTS is the initial scale-to-zero proof.

The following remain staged until their prerequisites/capacity gate is accepted:

- Stalwart/Bulwark;
- Twenty;
- Chatwoot;
- La Suite Messages;
- Renovate;
- Paperless-ngx;
- Dawarich;
- Metabase;
- Argo MCP until its read-only Argo token exists.

## Final report

Record only non-secret status:

```text
HOMELAB_INFRA_PR=
KUBE_OPS_PR=
PROXMOX_PLAN=
PROXMOX_APPLIED=
UNRELATED_CHANGE=NONE|...
TALOS_HEALTH=
KUBERNETES_NODE_READY=
CILIUM_HEALTH=
COREDNS_HEALTH=
PROXMOX_CSI_SMOKE=
DOPPLER_STORE_READY=
EXTERNALSECRETS_NOT_READY=
ARGO_DEGRADED_APPS=
AUTHENTIK_LOGIN=
MIGADU_SMTP_TEST=
HETZNER_BACKUP=
VELERO_RESTORE=
CNPG_RESTORE=
BLOCKERS=
NEXT_ACTION=
```
