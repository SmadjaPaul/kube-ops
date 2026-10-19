# DR cleanup live inventory — 2026-10-19

This inventory was collected from the canonical operator kubeconfig against
Kubernetes `v1.36.3` on 2026-10-19. Secret values are intentionally excluded.
It is a safety input for the separate cleanup manifests; it is not an
authorization by itself.

## Classification

| Lot | Classification | Reason |
| --- | --- | --- |
| `dr-pvc-proof-20261019193651` | DELETE candidate | Dedicated proof namespace. Four reader Pods are `Succeeded`; the four Longhorn volumes are `detached`, with no VolumeAttachment. The four remote Longhorn `Backup` CRs are preserved explicitly. |
| `dr-synth-20261019170700-cnpg-src` | DELETE candidate, Barman-gated | Dedicated synthetic namespace. One healthy CNPG Cluster, one completed Backup and one ObjectStore. The namespace contains one attached Longhorn data volume. No production owner or Argo Application references were found. |
| `dr-synth-20261019170700-cnpg-tgt` | DELETE candidate, Barman-gated | Dedicated synthetic recovery namespace. One healthy CNPG Cluster and two ObjectStores. The namespace contains one attached Longhorn data volume. No production owner or Argo Application references were found. |
| 17 historical PVCs | REVIEW | They are still mounted by active restore-drill workloads, including Invoice Ninja and OpenClaw. Some carry Argo tracking annotations. No historical PVC is eligible for automatic deletion. |

## CNPG/Barman objects

| Kind | Namespace | Name | UID | Finalizers | Phase | External path |
| --- | --- | --- | --- | --- | --- | --- |
| Cluster | `dr-synth-20261019170700-cnpg-src` | `dr-synth-20261019170700-cnpg` | `e96a6679-c96e-4f74-a420-20434b875467` | none | Cluster in healthy state | — |
| Backup | `dr-synth-20261019170700-cnpg-src` | `dr-synth-20261019170700-cnpg-backup` | `e6844b7e-12eb-4084-8e56-fa47c071e222` | none | completed | — |
| ObjectStore | `dr-synth-20261019170700-cnpg-src` | `dr-synth-20261019170700-store` | `29c158c5-699a-4840-b24b-4d150ce9348e` | none | — | `s3://smadja-dev-homelab-backups/cnpg/synthetic/dr-synth-20261019170700` |
| Cluster | `dr-synth-20261019170700-cnpg-tgt` | `dr-synth-20261019170700-cnpg-recovered` | `292456e8-f87b-447a-b851-6001370f05bb` | none | Cluster in healthy state | — |
| ObjectStore | `dr-synth-20261019170700-cnpg-tgt` | `dr-synth-20261019170700-source-store` | `c0c6e31f-c1de-419c-bc25-163ba308b17e` | none | — | `s3://smadja-dev-homelab-backups/cnpg/synthetic/dr-synth-20261019170700` |
| ObjectStore | `dr-synth-20261019170700-cnpg-tgt` | `dr-synth-20261019170700-target-store` | `db060443-73bf-4dcc-ac9e-bcfc643dbfa2` | none | — | `s3://smadja-dev-homelab-backups/cnpg/synthetic/dr-synth-20261019170700-target` |

All three ObjectStores use a one-day retention policy. The first source path
is referenced by two drill ObjectStores, so it is not a deletion target in
this mission. No S3 object or bucket is deleted by the cleanup engine.

## Storage candidates

### CNPG lot

| PV | PV UID | Claim | Claim UID | Handle | Longhorn volume UID | State |
| --- | --- | --- | --- | --- | --- | --- |
| `pvc-bcbd7819-98bc-44da-be48-7d591bdb0638` | `bf1714b0-8fe2-4434-af80-1de9bc56f1d7` | `dr-synth-20261019170700-cnpg-src/dr-synth-20261019170700-cnpg-1` | `bcbd7819-98bc-44da-be48-7d591bdb0638` | `pvc-bcbd7819-98bc-44da-be48-7d591bdb0638` | `95086901-0613-4a83-961b-e8853424001b` | attached / healthy |
| `pvc-5de7ece7-7662-441a-9037-285a501ed5e7` | `d9b4c296-e7bc-43fc-8db5-182c0672fdfe` | `dr-synth-20261019170700-cnpg-tgt/dr-synth-20261019170700-cnpg-recovered-1` | `5de7ece7-7662-441d-9037-285a501ed5e7` | `pvc-5de7ece7-7662-441d-9037-285a501ed5e7` | `3f0ec65c-d96f-4031-8f41-b54e30657bb9` | attached / healthy |

The CNPG Longhorn volumes must become detached only through normal namespace
and workload termination. The engine must stop on timeout or identity drift.

### Longhorn proof lot

| PV | PV UID | Claim UID | Handle | Longhorn volume | Volume UID | State |
| --- | --- | --- | --- | --- | --- | --- |
| `dr-proof-pv-agentgateway` | `0fcd1b2f-74e8-458f-9fc3-ad7deae1ebe3` | `72b8603f-6a2a-459c-a56c-3aab207a3941` | `dr-proof-restore-agentgateway` | `dr-proof-restore-agentgateway` | `d4a54f41-a862-4bc7-90aa-a4183da02cd9` | detached / unknown |
| `dr-proof-pv-atlantis` | `b906c204-1983-47a6-8320-35766dd8f6c7` | `bcaa81bf-f15b-4e30-b1d6-bce7ccaf8d5b` | `dr-proof-restore-atlantis` | `dr-proof-restore-atlantis` | `9623a303-90b0-4a19-bab3-48c614b52f79` | detached / unknown |
| `dr-proof-pv-listmonk` | `080e0dde-fa9b-4bc6-9877-ab49ce161829` | `9dd6a2b4-00b9-4c6c-b61d-65d01f9d0206` | `dr-proof-restore-listmonk` | `dr-proof-restore-listmonk` | `f229cbdc-865d-4c39-9aa4-6ee530a6fe10` | detached / unknown |
| `dr-proof-pv-twenty` | `9c972ceb-a44c-4465-8a45-36c5050f353e` | `6032fec8-3adf-436b-accd-caa8b64993ab` | `dr-proof-restore-twenty` | `dr-proof-restore-twenty` | `986bea05-cd4c-4425-a523-ec081034cfc4` | detached / unknown |

The proof namespace UID is `9546da89-b8c5-453f-9a59-bb5042ab8ad6`. Its four
reader Pods all completed and are the only workload references observed. No
VolumeAttachment references any of the four proof PVs.

The four preserved remote backups are:

- `dr-proof-20261019193651-agentgateway` — `c45cb76a-c9f5-45b6-b35f-a7789f859c21`, Completed;
- `dr-proof-20261019193651-atlantis` — `d25f2673-1256-4386-a249-be9ae915fd99`, Completed;
- `dr-proof-20261019193651-listmonk` — `a1eadbf3-edd3-4f74-95da-834cf29851ce`, Completed;
- `dr-proof-20261019193651-twenty` — `4c74b3cb-b404-4462-b314-836b462ac543`, Completed.

## Historical PVCs — REVIEW only

All 17 remain intact because their namespaces still contain workloads or
network policies from the corresponding restore drills. This is a nominative
review inventory, not a deletion plan.

| Namespace | PVC | UID | Phase | Decision |
| --- | --- | --- | --- | --- |
| `invoice-ninja-restore-drill-20261009` | `data-invoice-ninja-mysql-0` | `51d97b5b-8880-4078-82d6-5acb724d40e6` | Pending | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-public` | `03f66755-a871-438e-9d8c-126faad321c2` | Pending | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-redis` | `096041b7-016c-4af7-8824-047065394c7a` | Pending | REVIEW |
| `invoice-ninja-restore-drill-20261009` | `invoice-ninja-storage` | `8872a515-3a0e-448e-aed8-1fbd7fff0565` | Pending | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `data-invoice-ninja-mysql-0` | `d4a2d766-20e7-495f-8e76-fd22015a65d5` | Bound | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-public` | `cb5dff28-fa32-4d7e-8981-4083edb5b837` | Bound | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-redis` | `5e302a5e-b830-4dab-b4a8-5b20a9f5e639` | Bound | REVIEW |
| `invoice-ninja-restore-drill-20261009-v2` | `invoice-ninja-storage` | `92a94764-f26f-4b7c-941d-1b16ac685103` | Bound | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-config-openclaw-0` | `40d1fa24-aa4a-4c3f-8aea-fc033cb1150c` | Pending | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-data` | `c7df5aaa-e900-49d2-9360-b25c90c243cf` | Bound | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-data-openclaw-0` | `11765724-6a47-4abb-8243-4066e371e359` | Pending | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-logs-openclaw-0` | `5102ec6a-bbb0-4ddd-a63c-d836a10070e8` | Pending | REVIEW |
| `openclaw-restore-drill-20261005` | `openclaw-workspace-openclaw-0` | `e749e9e6-1d07-474e-a5db-afd5a3394326` | Pending | REVIEW |
| `openclaw-restore-drill-20261005-v2` | `openclaw-data` | `bdabb517-22bf-4839-a28b-c48990d4b5c7` | Pending | REVIEW |
| `openclaw-restore-drill-20261005-v3` | `openclaw-data` | `5265d81b-cd13-4946-be0d-83d39a1d2809` | Pending | REVIEW |
| `openclaw-restore-drill-20261005-v4` | `openclaw-data` | `0672eeba-79e8-429d-99e3-ddde1f576d5f` | Bound | REVIEW |
| `openclaw-restore-drill-20261005-v5` | `openclaw-data` | `aff2eca4-a871-4f1e-97be-6d1fb7d9bd63` | Bound | REVIEW |

The bound historical PVs are retained. The Pending claims have no PV to
delete. Deleting a namespace or PVC in this lot would remove active drill
workloads and is not covered by the current automatic cleanup authorization.

## Preserved external evidence

The Velero/Kopia Backup, Restore, PVB and PVR objects for the synthetic drill,
the CNPG/Barman evidence and the four Longhorn qualification backups remain
outside the delete candidates. No bucket or S3 prefix is modified by these
manifests.
