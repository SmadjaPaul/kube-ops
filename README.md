# kube-ops

Canonical GitOps repository for the Smadja Kubernetes cluster.

## Ownership

`homelab-infra` owns everything below the Kubernetes API: Proxmox networking, VM101, Talos machine configuration/secrets/bootstrap, external providers and runtime credentials.

`kube-ops` starts at the Kubernetes API. It contains no Terraform/OpenTofu state and cannot create or destroy VM101.

## V1

- one schedulable Talos control-plane at `10.0.20.60`;
- Talos `1.13.10`, Kubernetes `1.36.3`;
- Gateway API `v1.6.1`;
- Cilium `1.20.2` with kube-proxy replacement;
- Argo CD as the steady-state reconciler;
- Proxmox CSI chart `0.5.12` / plugin `v0.20.0`;
- cert-manager + External Secrets/Doppler;
- CloudNativePG;
- Authentik;
- Velero/Kopia and CNPG Barman to Hetzner Object Storage;
- in-cluster cloudflared using the remotely-managed wildcard tunnel;
- Migadu retained for SMTP.

## Bootstrap

After `homelab-infra` has produced a healthy Talos/Kubernetes API and a kubeconfig:

```text
Gateway API CRDs
  -> Cilium
  -> External Secrets
  -> bootstrap Doppler token
  -> cert-manager
  -> Argo CD
  -> AppProjects/ApplicationSets
  -> Git -> Argo -> Kubernetes
```

Run:

```bash
./scripts/bootstrap-cluster.sh
```

The script consumes `DOPPLER_CLUSTER_TOKEN` when supplied. Otherwise it reads `ESO_CLUSTER` from Doppler `infrastructure/prd` through the authenticated Doppler CLI. It never prints the token.

After the root ApplicationSets exist, all normal changes are reconciled by Argo CD.

## Layout

- `k8s/infrastructure/`: cluster infrastructure desired state;
- `k8s/applications/`: first-green applications;
- `k8s/bootstrap/`: the tiny Argo root handoff only;
- `scripts/bootstrap-cluster.sh`: one-time/idempotent bootstrap;
- `images/`: custom images where upstream is insufficient;
- `website/`: inherited documentation source, not a runtime surface.

Run `npm run check:v1-contract` before deployment.
