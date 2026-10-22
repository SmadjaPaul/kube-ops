# Recovery consolidation — 2026-10-22

## Decision summary

| Lot | Status | Owner / cause | Decision |
| --- | --- | --- | --- |
| apps-media ExternalSecrets | **BLOCKED_EXTERNAL_CREDENTIAL** | Media owner / authoritative `cluster/prd` Doppler source lacks `APP_JELLYSEERR_JELLYFIN_API_KEY`; active workloads remain ready | No placeholder, no competing authority, no GitOps fix until the credential owner provisions the real key |
| CNPG `sure` isolated restore | **PASS — RUNTIME, bounded** | CNPG/Barman recovery path | One independent recovery succeeded; this does not generalize to the other 13 clusters |
| CNPG RPO | **UNPROVEN** | No independent pre-restore source LSN/transaction marker | Do not infer RPO from base-backup age |
| Restored application user journey | **NOT_EXECUTED** | Outside the isolated SQL qualification | Requires a separate isolated application-level test |
| OpenClaw consumer/decommission | **BLOCKED** | No active CR/service found, but token/audience references still require owner attribution; operator has repeated informer-cache failures | No deletion or GitOps decommission |
| Historical restore residues | **REVIEW** | Synthetic drill ownership and usefulness are not fully resolved | No mass deletion; PLT-105 is explicitly preserved |

The only temporary resources created by the CNPG qualification were in
`cnpg-restore-qual-sure-20261022`. They were deleted after verification. No
production CNPG cluster, WAL stream, state, Secret value, Factory resource,
Atlantis resource, Proxmox object or OpenTofu state was modified.

## CNPG runtime proof

Source `sure/sure-postgresql` was healthy with one ready instance and a
completed CNPG Backup `sure-postgresql-gap-remediation-20261019`, backup ID
`20261019T153211`, ending at `2026-10-19T15:32:16Z`. The isolated target used
the existing Hetzner ObjectStore path through a temporary `ExternalSecret`,
with a deny-by-default Cilium policy plus Kubernetes ingress deny.

The target `sure-postgresql-restore` reached `Cluster in healthy state`,
`Ready=True`, one ready instance, system ID `7693136689275056153`, and timeline
2. The restored SQL sentinel matched the source: 152 user tables, 456 total
rows, checksum `7cb71792812bcc683586784f24618c9b`, database `sure`, PostgreSQL
18.3 and `in-recovery=false`.

Observed timing was 66 seconds to `Ready=True` and 192 seconds to the SQL
sentinel. These are fixture measurements, not a platform-wide SLO. RPO was
not independently measured because no source LSN/transaction marker was
captured before recovery. The full application user journey was not executed.

Negative isolation probes all timed out as intended:

- source Pod -> target ingress: blocked;
- target Pod -> source database: blocked;
- target Pod -> public IP: blocked.

The exact temporary storage identities were PV
`pvc-193a9e05-f71e-4565-93fb-a72bb05748c9` (UID
`d4e71786-112f-4261-9c72-6ca4ed5c6e51`) and Longhorn volume of the same name
(UID `a1068aed-79f9-4a64-8154-d11a6bb1822a`). Both were deleted after the
namespace cleanup; no historical PV was selected.

## Apps-media

Argo reports `apps-media` `Synced/Degraded` at revision
`1a46a13fa174b986c74db3fa434d20ef2b79d2e0`, with 25 orphaned resources. The
two failing ExternalSecrets are `media/jellyseerr-secrets` and
`media/seerr-first-run`; both fail on the same missing Doppler key
`APP_JELLYSEERR_JELLYFIN_API_KEY`. The authoritative runtime project is
`cluster/prd`; `infrastructure/prd` is operator/bootstrap-only. No alternate
Jellyfin API-key source was found in the inspected homelab-infra authority.

The active media workloads are ready, so substituting a value would hide a
real dependency failure. The remediation is therefore blocked on the media
credential owner. PR #667 only documented the authority correction and did
not fabricate or rotate a credential.

## OpenClaw and active references

No `OpenClawInstance`, OpenClaw Service, or active OpenClaw route was found.
Invoice Ninja is `Synced/Healthy`; its MCP manifests are dormant and excluded
from the active Kustomization. The `openclaw-operator` Pod is currently
Running/Ready but has 59 restarts, and its logs contain repeated informer
cache-sync timeouts followed by manager shutdown. This is a demonstrated
operator defect, not evidence that the operator can be safely removed.

OpenClaw token/audience references remain in dormant or acceptance material,
including the Invoice Ninja MCP and Open WebUI acceptance mapping. Until the
application/platform owner confirms those references are historical, no
decommission PR is safe.

## Residual inventory — all 21 remain REVIEW

The live backup audit at `2026-10-22T15:35:27Z` reports 21 synthetic/test
restore PVC residues. None is an automatic deletion candidate:

| Namespace | PVC | UID | Current evidence | Decision |
| --- | --- | --- | --- | --- |
| `dr-protect-20261020-immich` | `restored-redis-data` | `503add93-4e98-461a-9d6c-764ad12fab98` | Longhorn S3 backup present; restore not verified | REVIEW |
| `dr-protect-20261020-mastra-active` | `restored-workspace` | `307469f9-65a5-4c24-ac5b-7478b8b9b496` | Longhorn S3 backup present; restore not verified | REVIEW |
| `dr-protect-20261020-mastra-suspended` | `restored-workspace` | `93656934-b7b9-4a60-aeda-5efca54d1bc8` | Longhorn S3 backup present; restore not verified | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `data-invoice-ninja-mysql-0` | `d4a2d766-20e7-495f-8e76-fd22015a65d5` | No correlated backup mechanism | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-public` | `cb5dff28-fa32-4d7e-8981-4083edb5b837` | No correlated backup mechanism | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-redis` | `5e302a5e-b830-4dab-b4a8-5b20a9f5e639` | No correlated backup mechanism | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-storage` | `92a94764-f26f-4b7c-941d-1b16ac685103` | No correlated backup mechanism | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `data-invoice-ninja-mysql-0` | `51d97b5b-8880-4078-82d6-5acb724d40e6` | Longhorn S3 backup present; restore not verified | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-public` | `03f66755-a871-438e-9d8c-126faad321c2` | Longhorn S3 backup present; restore not verified | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-redis` | `096041b7-016c-4af7-8824-047065394c7a` | Longhorn S3 backup present; restore not verified | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-storage` | `8872a515-3a0e-448e-aed8-1fbd7fff0565` | Longhorn S3 backup present; restore not verified | REVIEW |
| `openclaw-restore-drill-20261005-v2` | `openclaw-data` | `bdabb517-22bf-4839-a28b-c48990d4b5c7` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005-v3` | `openclaw-data` | `5265d81b-cd13-4946-be0d-83d39a1d2809` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005-v4` | `openclaw-data` | `0672eeba-79e8-429d-99e3-ddde1f576d5f` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005-v5` | `openclaw-data` | `aff2eca4-a871-4f1e-97be-6d1fb7d9bd63` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-config-openclaw-0` | `40d1fa24-aa4a-4c3f-8aea-fc033cb1150c` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-data` | `c7df5aaa-e900-49d2-9360-b25c90c243cf` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-data-openclaw-0` | `11765724-6a47-4abb-8243-4066e371e359` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-logs-openclaw-0` | `5102ec6a-bbb0-4ddd-a63c-d836a10070e8` | No correlated backup mechanism | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-workspace-openclaw-0` | `e749e9e6-1d07-474e-a5db-afd5a3394326` | No correlated backup mechanism | REVIEW |
| `plt105-recovery-20261020` | `plt105-recovery-pvc` | `95e7eaa9-c966-4825-8977-18ca826351c1` | Explicit PLT-105 preservation boundary | REVIEW |

## Validation boundary

This document is evidence, not a promotion of STATIC or RECONCILED state into
RUNTIME. The CNPG result is a single-cluster runtime recovery proof. The
repository-wide audit remains `CNPG_RESTORE_PROOF=UNPROVEN` until its contract
is intentionally extended to consume bounded, per-cluster application
recovery evidence.
