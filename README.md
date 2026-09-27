# kube-ops

Canonical Kubernetes GitOps repository for the Smadja home cluster.

## Ownership

`homelab-infra` creates and owns the substrate: Proxmox networking, VM101 / `10.0.20.60`, Talos machine lifecycle, external providers and bootstrap credentials.

`kube-ops` starts at the kubeconfig handoff and owns Kubernetes desired state.

There is intentionally no Terraform/OpenTofu state in this repository.

## V1

The first-green target is:

- one schedulable Talos control-plane node;
- Talos `v1.13.10` / Kubernetes `1.36.3`;
- Gateway API CRDs + Cilium `1.20.2`;
- External Secrets + Doppler;
- cert-manager;
- Argo CD as the sole steady-state reconciler;
- Proxmox CSI backed by `tank-vm`;
- CloudNativePG;
- Authentik;
- Velero/Kopia and CNPG Barman backups to Hetzner Object Storage;
- Migadu SMTP;
- GPT Researcher, Pocket-TTS and Whisper.

Business workloads, vLLM, Frigate and Minecraft stay outside first green.

## Bootstrap

After `homelab-infra` has created Talos and the operator has materialized its kubeconfig, run:

```text
DOPPLER_TOKEN=<cluster/prd scoped service token> ./scripts/bootstrap-cluster.sh
```

The script applies only the minimum chicken-and-egg components:

```text
Gateway API CRDs
  -> Cilium
  -> External Secrets
  -> Doppler access Secret
  -> cert-manager
  -> Argo CD
  -> infrastructure/application ApplicationSets
```

The manifests applied during bootstrap are the same Git-managed manifests Argo subsequently reconciles; bootstrap does not create a parallel desired-state system.

## Normal operation

After bootstrap the mutation path is:

```text
Git -> Argo CD -> Kubernetes
```

Run `npm run check:v1-contract` before merging Kubernetes changes.
