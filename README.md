# kube-ops

Canonical Kubernetes desired state for the Smadja homelab.

## Ownership boundary

`SmadjaPaul/homelab-infra` owns everything required to make the Kubernetes API reachable:

- Proxmox host/network;
- Talos VM101 and machine secrets;
- Proxmox CSI API identity;
- UniFi and AdGuard;
- Cloudflare account, DNS and Tunnel configuration;
- Doppler bootstrap/runtime domains;
- Hetzner Object Storage;
- Migadu.

This repository starts from a reachable Kubernetes API and owns:

- Cilium and Gateway API;
- Argo CD;
- cert-manager and External Secrets;
- Proxmox CSI Kubernetes controller/StorageClass;
- CloudNativePG;
- Authentik;
- observability/security controllers;
- applications.

There is intentionally **no OpenTofu/Terraform substrate code in this repository**.

## V1 cluster

```text
Proxmox: tatouine
Talos VM: homeops-01
VMID: 101
IP: 10.0.20.60/24
CPU: 6 vCPU
RAM: 32 GiB
OS disk: 100 GiB nvme-vm
Kubernetes: 1.36.3
Talos: 1.13.10
PVC backend: Proxmox CSI -> tank-vm
GitOps: Argo CD
```

The cluster is single-node and the control plane is schedulable.

## Bootstrap

The only imperative bootstrap is the chicken-and-egg path needed before Argo can reconcile itself.

Prerequisites:

- a kubeconfig produced by `homelab-infra`;
- `kubectl`;
- `kustomize`;
- the read-only Doppler `cluster/prd` service token in `DOPPLER_CLUSTER_TOKEN`.

Run:

```bash
export KUBECONFIG=/protected/path/kubeconfig
export DOPPLER_CLUSTER_TOKEN='<provided out of band>'
bash scripts/bootstrap-kubernetes.sh
```

The script installs:

```text
Gateway API CRDs v1.4.1
-> Cilium
-> cert-manager
-> External Secrets
-> Doppler ClusterSecretStore
-> Argo CD
-> canonical ApplicationSets
```

After that point Argo CD owns steady-state mutation. Do not use imperative application applies as an alternate control plane.

## External edge

Cloudflare owns one remotely managed wildcard Tunnel rule:

```text
*.smadja.dev
    -> cloudflared pod
    -> cilium-gateway-external.gateway.svc.cluster.local:443
    -> Gateway/gateway/external
    -> per-application HTTPRoute
```

Adding a normal public application therefore requires an `HTTPRoute` hostname, not a new Cloudflare Tunnel ingress rule or DNS record.

The bare apex `smadja.dev` is not covered by the wildcard Tunnel rule.

## Storage and backup

Application PVCs use `proxmox-csi` backed by `tank-vm`.

Offsite durability uses Hetzner Object Storage:

- CNPG: continuous WAL + weekly base backup, 14-day recovery window;
- Velero/Kopia: filesystem/Kubernetes-resource backup, 14-day TTL.

Do not introduce TrueNAS, NFS, MinIO or Backblaze merely to preserve the upstream repository shape.

## Secrets

Kubernetes consumes one read-only `ClusterSecretStore/doppler-cluster`.

Doppler remains external/bootstrap/recovery authority. Secret values never belong in Git, logs, plans or agent output.

OpenBao is a narrow exception used only as the Transit cipher backend for Omnigent's encrypted Credential Store.

## Scaling

KEDA + its HTTP add-on are installed. Pocket-TTS is the first scale-to-zero workload. Expand scale-to-zero only after measuring cold-start behavior.

## Validation

```bash
npm run check:v1-contract
npm run check:post-v1-staged
```

The active gate renders all reconciled roots, rejects legacy upstream/storage bindings, checks the Doppler secret contract, and forbids direct application `LoadBalancer`/`NodePort` Services.

The staged gate renders capacity- or bootstrap-gated applications without activating them.

## Related repository

External infrastructure and the destructive cluster replacement procedure live in:

```text
https://github.com/SmadjaPaul/homelab-infra
```
