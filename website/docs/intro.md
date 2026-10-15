---
title: Homelab architecture and operating guide
description: Current GitOps boundaries, operational entry points, and evidence needed before changing the homelab.
---

# Homelab architecture and operating guide

> **Documentation status — reviewed against Git on 2026-10-15.** Git describes desired state, not guaranteed live health. Verify Argo CD and runtime state before operating on resources. Older migration/runbook pages may describe historical configurations.

## Canonical repositories

| Repository | Owns | Does not own |
| --- | --- | --- |
| [kube-ops](https://github.com/SmadjaPaul/kube-ops) | Argo CD, Kubernetes manifests, application networking, in-cluster secrets delivery, backup configuration | Proxmox/Talos provisioning and external cloud resources |
| [homelab-infra](https://github.com/SmadjaPaul/homelab-infra) | Proxmox, Talos bootstrap, Cloudflare/UniFi and external providers, OpenTofu state | Kubernetes application desired state |
| [factory-platform](https://github.com/SmadjaPaul/factory-platform) | Mastra Factory, CI/CD code, harnesses and Data Platform dbt models | Live GitOps image digests |
| [website](https://github.com/SmadjaPaul/website) | Public sites and Sanity Studio | Kubernetes infrastructure and homelab documentation |

**Delivery model:** Git → Argo CD → Kubernetes. CI publishes images; deployments are pinned to an immutable digest in kube-ops. A built image is not a deployed image.

## Current platform components

- **Compute:** Proxmox VE hosts the Talos Kubernetes VM; Talos bootstrap belongs to homelab-infra.
- **Networking:** Cilium and Kubernetes Gateway API provide internal and externally routed traffic; external exposure is route-specific, not automatic.
- **Reconciliation:** Argo CD + Kustomize manage Kubernetes desired state.
- **Identity and secrets:** Authentik supports app SSO where configured; External Secrets handles in-cluster delivery. Mastra Factory has its own application authentication contract.
- **State and recovery:** Longhorn for application volumes, CloudNativePG for PostgreSQL, and Velero/Kopia plus database backups for disaster recovery.

See [architecture](./architecture), [local-first networking](./local-first-network), [infrastructure overview](./infrastructure/overview), and [disaster recovery](./disaster/disaster-recovery).

## Software Factory

Mastra Factory manifests live under [`k8s/applications/platform/mastra-factory`](https://github.com/SmadjaPaul/kube-ops/tree/main/k8s/applications/platform/mastra-factory).
Its full web UI is routed through the **internal Gateway**. Only the signed GitHub webhook has an external HTTPRoute; do not expose the UI merely to enable remote development.

Cloud Build/GHCR work is tracked in [factory-platform PR #54](https://github.com/SmadjaPaul/factory-platform/pull/54) and [homelab-infra PR #127](https://github.com/SmadjaPaul/homelab-infra/pull/127). PRs are *proposals*, not automatically deployed capability.

Paperclip is being decommissioned via [kube-ops PR #494](https://github.com/SmadjaPaul/kube-ops/pull/494). Historical Paperclip instructions must not be treated as current operating guidance.

## Organization and operating model

The internal AI-native Shared Operations department now uses five durable outcomes (O1–O5), nine operational capabilities (C1–C9) and seven IT4IT value streams (VS1–VS7) to discover and route work across repositories and services. See [Operating Model V3](./organization/operating-model) for responsibilities, service and task decision boundaries, the draft versioned strategy and how agents should treat runtime versus static evidence.

This is **governance and navigation**, not proof of production agent execution or an invitation to publish private operational information. The Git strategy and metrics remain pending human approval.

## Where to start

- **Provisioning:** [homelab-infra](https://github.com/SmadjaPaul/homelab-infra) and its documented bootstrap procedures; avoid copying old Terraform commands from historical migration pages.
- **Daily Kubernetes operations:** [Kubernetes management](./k8s/manage-kubernetes), then validate the exact live Argo Application and resource before making changes.
- **Application changes:** [Application management](./k8s/applications/application-management).
- **Contribution and evidence:** [Contributing guide](./contributing/overview) and [quality reviews](./contributing/code-quality-and-agent-reviews).
- **Incident recovery:** [Disaster recovery](./disaster/disaster-recovery) and tested restore procedures.

## Documentation hygiene

Docusaurus **publishes** documentation stored in Git; it is not a separate authority. Each substantial update should cite its canonical code/config source, distinguish **current / proposed / historical**, and be validated by a Docusaurus build plus targeted source checks. Broken links or stale runbooks are findings, not grounds for silent deletion of production manifests.
