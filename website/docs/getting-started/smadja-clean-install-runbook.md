---
sidebar_position: 7
title: Smadja clean-install migration runbook (superseded)
description: Compatibility pointer to the canonical V1 migration runbook.
---

# Smadja clean-install migration runbook

This page is retained only to avoid stale links.

The **authoritative** execution contract is [Smadja V1 clean-install agent runbook](./smadja-v1-clean-install-agent-runbook.md). The canonical scope is [Smadja V1 scope](./smadja-v1-scope.md), and the remaining pre-cutover work is tracked in [Smadja environment porting TODO](./smadja-porting-todo.md).

Do not execute instructions from older revisions of this page. In particular, V1 uses:

- Talos `v1.13.10`;
- Kubernetes `1.36.3`;
- no Talos VIP;
- `ClusterSecretStore/doppler-cluster`, never `bitwarden-backend`;
- Proxmox CSI on `tank-vm`;
- no active upstream NFS, TrueNAS, MinIO or B2 dependency; CNPG and Velero use Hetzner Object Storage directly;
- destructive retirement of the old VM101 followed by a fresh VM101 from `kube-ops` state.

The canonical runbook is the only migration authority.
