---
title: 'Longhorn Storage Removal'
---

:::danger Superseded — opposite of the V1 contract
This document describes a historical Longhorn-removal plan that was authored against an earlier architecture. It is **not** the V1 plan and **must not** be followed on the Smadja V1 platform.

The V1 contract (see `../../AGENTS.md`) is the inverse of what this file says:

- Longhorn is the V1 application storage plane, exposed through `longhorn-fast` and `longhorn-bulk` on dedicated Talos UserVolumes.
- Proxmox CSI is compatibility/staged only; it must not become the default storage class for new V1 workloads.
- The Longhorn Helm chart renders `createStorageClass: false` and `defaultClass: false` so neither Longhorn nor Proxmox CSI is auto-selected; every PVC must declare its class explicitly.

If you arrived here looking for how to operate Longhorn or proxmox-csi on V1, read:

- [`../../AGENTS.md`](../../AGENTS.md) — canonical V1 storage contract.
- [`../../CLAUDE.md`](../../CLAUDE.md) — operator guidance.
- [`../../../k8s/infrastructure/storage/longhorn/`](../../../k8s/infrastructure/storage/longhorn/) — rendered Longhorn chart values and StorageClasses.
- [`../../../k8s/infrastructure/storage/proxmox-csi/`](../../../k8s/infrastructure/storage/proxmox-csi/) — rendered proxmox-csi chart values and StorageClass.
- [`scripts/check-v1-active-contract.sh`](../../../scripts/check-v1-active-contract.sh) — structural gate that fails on legacy bindings and on `proxmox-csi` becoming the default class.

The body of this file is retained unchanged as a record of what the previous plan was, so that anyone who finds it through stale links can recognise it as superseded and follow the V1 contract instead.
:::