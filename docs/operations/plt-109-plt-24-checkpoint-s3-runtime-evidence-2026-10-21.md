# PLT-109 / PLT-24 — runtime evidence after #628

Date: 2026-10-21  
Kubernetes desired-state revision: `a75d3de45d33346227450ef171f4804bd61a6d61`  
Factory `origin/main`: `a0a02766a59944ef619964be1f7f641bd89c1703`

This document records runtime evidence only. It does not promote a static
contract to a runtime pass and it does not activate checkpoint delivery.

## Reconciled state

- `apps-platform`: `Synced` / `Healthy`, reconciled revision `a75d3de45`.
- Factory Pod: Ready and Running.
- `mastra-factory-checkpoint-s3` ExternalSecret: intentionally absent from the
  active Kustomization; the dormant manifest remains unactivated.
- `mastra-factory-checkpoint-s3` Secret: absent.
- Factory Deployment: optional `envFrom` reference remains present, so a
  missing checkpoint Secret does not activate the feature.
- GC: inactive. PLT-100: OFF.

The global `just backup-audit` still reports pre-existing platform backup
gaps and unproven general restore coverage. That is separate evidence and is
not counted as Factory checkpoint proof.

## Identity and effective permissions

Names-only Doppler inspection of `infrastructure/prd` found these existing
S3 keys:

- `HETZNER_S3_ACCESS_KEY_ID`
- `HETZNER_S3_SECRET_ACCESS_KEY`

The seven Factory keys are absent:

- `FACTORY_CHECKPOINT_S3_ENDPOINT`
- `FACTORY_CHECKPOINT_S3_REGION`
- `FACTORY_CHECKPOINT_S3_BUCKET`
- `FACTORY_CHECKPOINT_S3_PREFIX`
- `FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID`
- `FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY`
- `FACTORY_CHECKPOINT_INTERVAL_SECONDS`

The existing key was used only for a bounded, disposable probe. Effective
read/list access was observed as follows; counts are object counts, not object
contents:

| Prefix | Result |
| --- | --- |
| `factory-checkpoints/v1/fixture/` | allowed, 0 objects at probe time |
| `cnpg/` | allowed, 21 objects |
| `velero/` | allowed, 3 objects |
| `longhorn/` | allowed, 1 object |

This is a policy-isolation failure for Factory. The existing key is not wired
to Factory and must not be copied into the seven Factory keys. No CNPG,
Velero or Longhorn object was read, modified or deleted by the fixture.

Hetzner documents that keys in the same Object Storage project are
project-wide by default. Its documented same-bucket `DenyAllUsersButOne`
pattern can restrict a bucket to one access key, but the exact policy must be
applied and verified by the external bucket owner. Hetzner also warns that
such a restriction can affect object listing in the Console. See the
[Hetzner S3 credentials FAQ](https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/)
and [S3 key generation guide](https://docs.hetzner.com/storage/object-storage/getting-started/generating-s3-keys/).

The minimum next step is a dedicated key in the existing project plus a
same-bucket policy that is independently qualified with read-only and
disposable canaries. An `Allow` for `factory-checkpoints/v1/*` alone is not
accepted as proof of denial outside the prefix. Until the dedicated key and
effective denial are proven, ESO remains dormant.

## S3 runtime fixture

All objects were under `factory-checkpoints/v1/fixture/` or the disposable
`factory-checkpoints/v1/fixture-runtime/` prefix. The shared existing key was
used only because the Factory key is absent; this qualifies transport, not
isolation.

### Bundle/manifest fixture

Result: `S3_FIXTURE_RUNTIME=PASS` for the disposable transport sequence.

- Capture: `20261021T211353Z-AD161461EEA4`
- Bundle key: `factory-checkpoints/v1/fixture/20261021T211353Z-AD161461EEA4.bundle`
- Manifest key: `factory-checkpoints/v1/fixture/20261021T211353Z-AD161461EEA4.manifest.json`
- Bundle size: `8947767` bytes
- Local SHA-256: `5dcd401ef44e69bd943bdc9a07d96d1aa4e7fb3525deb5728069cc23b1f31ac4`
- Download size/SHA-256: identical
- LIST result: 2 objects after bundle then manifest publication
- Timings: PUT 3 s; manifest PUT 0 s
- DELETE: only the two disposable objects; remaining fixture objects: 0

### Binding refusal fixture

Result: `S3_BAD_BINDINGS=PASS` against a manifest fetched from the live bucket
through Factory main's `readCheckpointManifest` validator.

- Capture: `20261021T211541Z-17F753BB10C0`
- Manifest key: `factory-checkpoints/v1/fixture-runtime/20261021T211541Z-17F753BB10C0.manifest.json`
- Valid binding: accepted.
- Wrong `sessionId`, `workItemId`, `repository` and `branch`: each refused by
  manifest validation.
- Cleanup: `FIXTURE_CLEANUP=PASS`; remaining fixture objects: 0.

The negative policy check did not pass: the current shared key could list
outside the Factory prefix. No negative write/delete was attempted against
CNPG, Velero or Longhorn.

## Claim-loss and recovery

`CLAIM_LOSS_RESTORE=NOT_EXECUTED`. No SandboxClaim was created, interrupted or
deleted. This is intentional: there is no dedicated Factory identity or
qualified effective policy, so creating a claim would not test the approved
Factory runtime path. PLT-105, fixtures #130/#134 and active sessions remain
untouched.

| Measure | Result |
| --- | --- |
| S3 disposable transport | RUNTIME PASS |
| S3 effective Factory isolation | RUNTIME FAIL / activation blocked |
| Bad session/repository/branch/Work Item bindings | RUNTIME PASS |
| Claim-loss restore | NOT_EXECUTED |
| RPO | UNKNOWN |
| RTO | UNKNOWN |
| Destructive GC | INACTIVE |

PLT-109 is therefore not complete. A later activation PR must add the seven
keys through Doppler → ESO, prove the dedicated-key policy, and then run the
strictly disposable claim-loss drill before any RPO/RTO value is recorded.

