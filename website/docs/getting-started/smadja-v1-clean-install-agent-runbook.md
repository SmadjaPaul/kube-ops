---
sidebar_position: 6
title: Smadja V1 clean-install agent runbook
description: Authoritative execution handoff for the agent performing the destructive V1 migration.
---

# Smadja V1 clean-install agent runbook

This document is the execution contract for the agent performing the V1 migration.

The goal is **not** to preserve the current Kubernetes cluster. The current cluster has no application data that must survive. The goal is the shortest safe path to a stable replacement based on the `SmadjaPaul/kube-ops` fork.

Read, in order:

1. repository `AGENTS.md`;
2. this runbook;
3. `smadja-v1-scope.md`;
4. `smadja-porting-todo.md`;
5. only the files required by the current phase.

Do not redesign the platform during the migration.

## Immutable decisions

Do not reopen these decisions unless runtime evidence proves them impossible:

- one schedulable Talos control plane;
- Proxmox host `tatouine`;
- VMID `101`;
- node IP `10.0.20.60/24`;
- no worker VM;
- no Talos VIP;
- no dedicated load-balancer VM;
- no BGP for first boot;
- Talos `v1.13.10`;
- Kubernetes `1.36.3`;
- 100 GiB OS disk on `nvme-vm`;
- application PVCs through Proxmox CSI on `tank-vm`;
- old 10 TiB Kubernetes guest disk is disposable;
- new cluster OpenTofu state is fresh: `kube-ops/homeops/terraform.tfstate`;
- no cross-repository state move/import;
- Doppler is the External Secrets backend;
- Migadu remains the V1 hosted mail/SMTP provider;
- GPT Researcher, Pocket-TTS and Whisper remain enabled;
- vLLM, Frigate, Minecraft and the business stack remain disabled for first green;
- Hetzner Object Storage is the V1 offsite backup backend; CNPG and Velero are enabled before first-green acceptance;
- Kubernetes UniFi Network Application remains disabled because the UGC Fiber owns UniFi Network.

## Repository boundary

`SmadjaPaul/homelab-infra` owns:

- physical Proxmox host/network;
- UniFi;
- AdGuard;
- Cloudflare external account/tunnel/DNS resources;
- Doppler projects/configs/service tokens;
- OCI external infrastructure and existing Terraform states;
- Migadu.

`SmadjaPaul/kube-ops` owns after cutover:

- the Talos VM lifecycle for VM101;
- Kubernetes;
- Argo CD;
- Cilium/Gateway;
- Proxmox CSI;
- External Secrets;
- Authentik;
- applications;
- cluster observability/security.

The old VM101 is destroyed by `homelab-infra` through its current state. Only after that destroy succeeds may `kube-ops` create VM101 in its fresh state.

## Hard stop conditions

Stop before mutation if any of the following is true:

- current VM101 contains data the operator now wants to preserve;
- `homelab-infra` Proxmox plan mutates `bond0`, `vmbr0`, ZFS/tank, unrelated VMs/LXCs, UniFi, Cloudflare, OCI or Migadu;
- a plan attempts a state move/import/backend migration;
- `kube-ops` plan contains a destroy of an existing external resource;
- VMID 101 or `10.0.20.60` is still occupied when the new cluster is about to be created;
- an active manifest still references `peekoff.com`, upstream `10.25.150.*` addresses, `Nvme1`, `velocity`, upstream TrueNAS, or upstream personal identities;
- a secret value would need to be printed or committed to proceed;
- Proxmox CSI cannot safely target `tank-vm`;
- static validation is not green.

A missing optional application secret is not a reason to redesign the secret architecture. Disable the optional application or materialize the required key in Doppler.

## Phase 0 — static convergence

Work only in the existing PR branches. Do not mutate live infrastructure.

### 0.1 Prove no active upstream environment remains

Search at minimum:

```bash
git grep -nE 'peekoff\.com|10\.25\.150\.|Nvme1|velocity|host3|bitwarden-backend' -- k8s tofu
```

Classify every hit as:

- active and must be ported;
- disabled/reference-only and safe to leave;
- documentation that must be corrected because it can mislead the migration.

Do not blind-replace IP addresses.

### 0.2 Render active Kubernetes roots

Render the same roots Argo will reconcile and fail on every error.

The canonical first gate is:

```bash
npm run check:v1-contract
```

It renders the active Argo roots, rejects legacy upstream/storage/secret-provider bindings, validates that active ExternalSecrets use `doppler-cluster` with `UPPER_SNAKE_CASE` keys, and emits the required Doppler **key names only**.

Where direct rendering is necessary:

```bash
kustomize build --enable-helm k8s/infrastructure/controllers >/dev/null
kustomize build --enable-helm k8s/infrastructure/network >/dev/null
kustomize build --enable-helm k8s/infrastructure/storage >/dev/null
kustomize build --enable-helm k8s/infrastructure/database >/dev/null
kustomize build --enable-helm k8s/infrastructure/auth >/dev/null

kustomize build --enable-helm k8s/applications/ai >/dev/null
kustomize build --enable-helm k8s/applications/media >/dev/null
kustomize build --enable-helm k8s/applications/automation >/dev/null
kustomize build --enable-helm k8s/applications/web >/dev/null
kustomize build --enable-helm k8s/applications/tools >/dev/null
```

Disabled business/backup/network applications must not appear in rendered output.

### 0.3 Validate OpenTofu without touching live state

Run the repository-native checks, plus:

```bash
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu init -backend=false
tofu -chdir=tofu validate
```

Do not run an apply in this phase.

## Phase 1 — Doppler preparation

The target ESO store is `ClusterSecretStore/doppler-cluster`.

### 1.1 Create the scoped runtime domain

In `homelab-infra/terraform/doppler`, the desired V1 resources are:

```text
project: cluster
config:  prd
service token: eso-cluster (read-only)
bootstrap reference: infrastructure/prd:ESO_CLUSTER
```

Plan first. Apply only the Doppler root; do not alter unrelated roots.

### 1.2 Inventory required secret names

Inventory secret **names only** from rendered active `ExternalSecret` resources.

Requirements:

- every active `secretStoreRef.name` is `doppler-cluster`;
- every active `remoteRef.key` is `UPPER_SNAKE_CASE`;
- do not inspect or report secret values.

Use the key-name list emitted between `ACTIVE_DOPPLER_REQUIRED_KEYS_BEGIN` and `ACTIVE_DOPPLER_REQUIRED_KEYS_END` as the canonical required set.

Compare those names with `cluster/prd` and, when a target key is absent, with the existing Doppler domains:

```text
edge/prd
identity/prd
apps/prd
storage/prd
crypto/prd
```

Maintain a value-free convergence report with one of these statuses per required key:

```text
READY
FOUND_SOURCE
GENERATE
MISSING_EXTERNAL
```

Populate `cluster/prd` using existing values when continuity matters. Generate new values for disposable application secrets when continuity is irrelevant. Any `MISSING_EXTERNAL` key required by an enabled application is a pre-cutover blocker.

Do not migrate anything to Bitwarden.

### 1.3 Required Migadu SMTP contract

Authentik must have:

```text
MIGADU_SMTP_HOST
MIGADU_SMTP_PORT
MIGADU_SMTP_USER
MIGADU_SMTP_PASSWORD
MIGADU_SMTP_FROM
```

A successful SMTP test is part of V1 acceptance.

## Phase 2 — prepare the destructive Proxmox cutover

Switch to the `homelab-infra` PR.

Initialize the existing backend exactly as documented by that repository, then:

```bash
just plan proxmox
```

The expected destructive set is the legacy Talos module and its module-owned resources. In particular, destroying the disposable VM101 and its disposable 10 TiB guest data disk is intentional.

There must be **no** unrelated mutation.

Record the plan summary and the exact resource addresses scheduled for destruction in the PR or execution report. Do not include secret/state values.

The apply is a human approval gate.

## Phase 3 — destroy the old cluster

After explicit operator approval:

1. apply the reviewed `homelab-infra/terraform/proxmox` plan;
2. verify VM101 is absent in Proxmox;
3. verify `10.0.20.60` is no longer in use;
4. verify `bond0`, `vmbr0`, `tank`, `nvme-vm`, `tank-vm` and `tank-iso` remain healthy;
5. do not create a temporary replacement cluster.

From this point, `homelab-infra` must not recreate Talos VM101.

## Phase 4 — initialize fresh kube-ops state

Use the existing OCI bucket with the **new key only**:

```text
kube-ops/homeops/terraform.tfstate
```

No migration, import, copy or state manipulation from the old Proxmox state.

Provide credentials through the established operator/Doppler flow, never committed tfvars.

Plan the new cluster.

Expected substrate:

```text
homeops-01
VMID 101
10.0.20.60/24
tatouine
6 vCPU
32 GiB RAM
100 GiB root disk on nvme-vm
no extra 10 TiB guest disk
no worker
no LB VM
no BLE proxy VM
```

The Talos/Kubernetes bootstrap path must use `10.0.20.60` directly. Public DNS is only a certificate SAN / later access surface and must not be required to bootstrap.

## Phase 5 — create the cluster

After explicit approval of the fresh-state plan:

1. apply the `kube-ops` Talos substrate;
2. verify Talos health;
3. verify Kubernetes API on `10.0.20.60:6443`;
4. verify the single node is Ready and schedulable;
5. verify Cilium;
6. verify CoreDNS;
7. verify Gateway API CRDs/controllers;
8. stop here on any network or DNS instability.

Do not start debugging optional applications until this layer is fully green.

## Phase 6 — storage and secrets

### Proxmox CSI

Prove:

- StorageClass `proxmox-csi` exists and is default as intended;
- datastore is `tank-vm`;
- a small smoke PVC binds;
- a pod can write/read a file;
- deleting the smoke workload behaves as expected under the selected Retain policy.

Do not reintroduce the old giant hostpath/OpenEBS disk.

The V1 media share is intentionally a 2 TiB `ReadWriteOnce` PVC on `proxmox-csi`. This is valid for the single-node V1 because the consuming pods are co-located on the same Kubernetes node. Do not add NFS merely to preserve the upstream RWX shape. If a future multi-node topology needs concurrent cross-node mounts, revisit RWX as a separate architecture change.

### External Secrets

Bootstrap the `doppler-access-token` secret without printing the token.

Prove:

```bash
kubectl get clustersecretstore doppler-cluster
kubectl get externalsecret -A
```

Every required active ExternalSecret must reach Ready before dependent apps are debugged.

## Phase 7 — Argo and core platform

Bootstrap Argo CD and reconcile infrastructure in this order:

1. controllers;
2. network;
3. storage;
4. database;
5. auth;
6. monitoring/security;
7. applications.

Do not compensate for a broken desired state with permanent imperative `kubectl apply` patches. Temporary runtime diagnostics are acceptable; durable fixes go to Git.

## Phase 8 — Authentik

Use the Smadja group taxonomy only:

```text
family
media
dev
data
iot
admin
authentik-admins
```

Do not import upstream users.

Acceptance:

- database Ready;
- server/worker Ready;
- login works;
- OIDC discovery works;
- group claims are present;
- Migadu SMTP sends a test message.

## Phase 9 — application layers

Keep one replica unless a component requires multiple distinct roles.

### Must remain enabled

```text
GPT Researcher
Pocket-TTS
Whisper ASR
OpenWebUI
LiteLLM
OpenCode
OpenClaw
Qdrant
Home Assistant
MQTT
Zigbee2MQTT
Matter Server
Immich
selected media/personal apps
```

### Must remain disabled for first green

```text
vLLM local inference
Frigate
Minecraft
Kubernetes UniFi Network Application
Stalwart
Bulwark / jmap-webmail
TMail
La Suite Messages
Listmonk
Twenty
Chatwoot
SES
Velero and CNPG offsite schedules
```

An optional app that blocks the cluster for an upstream-specific dependency should be disabled and reported, not allowed to delay the stable core.

## V1 backup contract — Hetzner Object Storage

The canonical offsite backend is:

```text
provider: Hetzner Object Storage
location: fsn1 (Falkenstein)
endpoint: https://fsn1.your-objectstorage.com
bucket: smadja-dev-homelab-backups
visibility: private
object lock: disabled for V1
versioning: disabled for V1
```

Hetzner documents `fsn1.your-objectstorage.com` as the Falkenstein S3 endpoint. Ingress and S3 API requests are not charged; V1 therefore optimizes primarily for retained object volume rather than upload frequency.

Doppler `cluster/prd` must contain:

```text
HETZNER_S3_ACCESS_KEY_ID
HETZNER_S3_SECRET_ACCESS_KEY
HETZNER_S3_VELERO_REPOSITORY_PASSWORD
```

No credential value may be printed.

CNPG contract:

```text
WAL archive: continuous
archive_timeout: CNPG default (5m)
WAL compression: gzip
maxParallel: 2
base backup: weekly, staggered on Sunday
recovery window: 14d
prefix: cnpg/<cluster>
```

Velero contract:

```text
backend: same Hetzner bucket
prefix: velero/
uploader: Kopia
parallelFilesUpload: 2
schedule: daily for enabled V1 stateful workloads
TTL: 14d
secondary weekly B2 tier: removed
disabled-app schedules: not active
```

CNPG protects PostgreSQL/PITR. Velero protects Kubernetes resources and non-database persistent data. Do not create a MinIO/Garage dependency merely for backup.


## Phase 10 — edge cutover

Only after internal health is proven:

1. validate the Cilium external Gateway service/IP;
2. update or verify the existing Cloudflare wildcard tunnel contract in `homelab-infra`;
3. keep Cloudflare external provisioning out of `kube-ops`;
4. verify selected public hostnames one by one;
5. verify Authentik protection/OIDC for exposed applications.

Do not use a broad catch-all route that bypasses authentication.

## Phase 11 — prove restore

Backup is part of V1 desired state, but durability is not proven until restore is tested.

1. verify every CNPG ObjectStore is reachable and WAL archiving progresses;
2. verify each weekly ScheduledBackup can complete against Hetzner;
3. verify Velero's default BackupStorageLocation is Available;
4. execute one small Velero backup/restore smoke test;
5. restore one disposable CNPG database from Hetzner and verify PITR mechanics;
6. record retained size and reassess the 14-day policy after real usage is observed.

Do not resurrect upstream TrueNAS/MinIO/B2 assumptions.

## Final report

The executing agent must finish with a concise report containing:

```text
HOMELAB_INFRA_PR=
KUBE_OPS_PR=

LEGACY_DESTROY_PLAN=
LEGACY_DESTROY_APPLIED=
UNRELATED_DESTROY_OR_CHANGE=NONE|...

NEW_STATE_KEY=kube-ops/homeops/terraform.tfstate
NEW_CLUSTER_PLAN=
NEW_CLUSTER_APPLIED=

TALOS_HEALTH=
KUBERNETES_NODE_READY=
CILIUM_HEALTH=
COREDNS_HEALTH=
GATEWAY_HEALTH=
PROXMOX_CSI_SMOKE=
DOPPLER_STORE_READY=
EXTERNALSECRETS_NOT_READY=
DOPPLER_REQUIRED_KEYS=
DOPPLER_MISSING_EXTERNAL_KEYS=
ACTIVE_LEGACY_STORAGE_REFERENCES=0
HETZNER_BACKUP_LOCATION=
CNPG_WAL_ARCHIVE=
VELERO_STORAGE_LOCATION=
RESTORE_SMOKE=

ARGO_DEGRADED_APPS=
AUTHENTIK_LOGIN=
MIGADU_SMTP_TEST=

GPT_RESEARCHER=
POCKET_TTS=
WHISPER=

DISABLED_BY_DESIGN=
BLOCKERS=
NEXT_ACTION=
```

Do not report V1 complete while unexplained Argo degradation remains in an application that is supposed to be enabled.
