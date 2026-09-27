# kube-ops

Canonical GitOps repository for the Smadja home Kubernetes cluster.

## V1

The first-green deployment is intentionally small and rebuildable:

- AOOSTAR WTR Max / Proxmox host `tatouine`;
- one schedulable Talos control-plane VM: VM101 / `10.0.20.60`;
- Talos `v1.13.10` and Kubernetes `1.36.3`;
- Cilium + Gateway API;
- Argo CD as the steady-state reconciler;
- Proxmox CSI for persistent volumes;
- CloudNativePG;
- cert-manager;
- External Secrets with Doppler;
- Authentik;
- Velero/Kopia and CNPG Barman backups to Hetzner Object Storage;
- Migadu retained for SMTP;
- GPT Researcher, Pocket-TTS and Whisper retained.

The business stack, vLLM, Frigate, Minecraft and other post-V1 expansion remain outside the first-green ApplicationSets.

## Repository boundary

`kube-ops` owns the disposable Talos VM lifecycle for this cluster and all Kubernetes/Argo desired state.

`homelab-infra` owns physical/external infrastructure such as Proxmox host configuration, UniFi/LAN, Cloudflare DNS/Tunnel, Doppler bootstrap, Hetzner Object Storage and Migadu.

## Deployment model

The intended path is:

```text
OpenTofu -> Talos -> Cilium bootstrap -> cert-manager -> External Secrets
-> Doppler access -> Argo CD -> infrastructure ApplicationSet
-> applications ApplicationSet
```

After bootstrap, Kubernetes changes flow through Git -> Argo CD -> Kubernetes.

Before any live apply, run `npm run check:v1-contract`, OpenTofu validation, and review the full plan. Destructive Proxmox actions are never implicit.

## Layout

- `tofu/`: Talos VM provisioning and bootstrap.
- `k8s/infrastructure/`: cluster infrastructure managed by Argo CD.
- `k8s/applications/`: user-facing workloads managed by Argo CD.
- `images/`: custom container images when an upstream image is insufficient.
- `website/`: inherited documentation source; it is not part of the V1 runtime deployment.

## V1 invariants

Active V1 desired state must not depend on the upstream `theepicsaxguy/homelab` repository, `peekoff.com`, TrueNAS/NFS, MinIO, Backblaze B2, Bitwarden or `proxmox-csi-2`.

The canonical repository is `https://github.com/SmadjaPaul/kube-ops.git`.
