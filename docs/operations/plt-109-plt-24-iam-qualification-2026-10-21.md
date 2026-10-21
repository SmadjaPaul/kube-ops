# PLT-109 / PLT-24 — Hetzner IAM qualification and restoration gate

Date: 2026-10-21  
kube-ops reconciled revision: `b578b6e81c0e0100e1e1669f32f3be276363b9a8`  
Factory main used by the prior runtime fixture: `a0a02766a59944ef619964be1f7f641bd89c1703`

This is a qualification record. It does not apply a Hetzner bucket policy,
create credentials, write Doppler values, activate ESO, create a SandboxClaim,
or delete any object.

## Current runtime boundary

- Bucket: `smadja-dev-homelab-backups`
- Region: `fsn1`
- Endpoint: `https://fsn1.your-objectstorage.com`
- Factory object prefix: `factory-checkpoints/v1/`
- Prior transport fixture: RUNTIME PASS
- Prior manifest/checksum/binding refusal fixture: RUNTIME PASS
- Current shared S3 identity: IAM FAIL for least-privilege Factory use
- Factory seven-key set: absent from Doppler `infrastructure/prd`
- `mastra-factory-checkpoint-s3` ExternalSecret: dormant/not in active Kustomization
- `mastra-factory-checkpoint-s3` Secret: absent
- Factory Pod: Ready/Running
- GC: INACTIVE
- PLT-100: OFF

After #631, `apps-platform` is `Synced/Healthy` at the reconciled revision
above. The Deployment still imports the checkpoint Secret optionally, so the
missing Secret does not activate checkpoint storage.

## Hetzner policy capability matrix

This matrix distinguishes what Hetzner documents from what remains unqualified
for this shared bucket:

| Feature | Result | Evidence / consequence |
| --- | --- | --- |
| Same-project key default scope | SUPPORTED, broad | Each key is valid for every existing and new bucket in its project. |
| `Principal` with a specific key | DOCUMENTED | Hetzner shows a key principal in its cross-project allow example. |
| `NotPrincipal` with a specific key | DOCUMENTED | Hetzner shows `DenyAllUsersButOne` for a whole-bucket allowlist. |
| `Effect: Deny` and `Action: s3:*` | DOCUMENTED | Used by Hetzner's same-project example. |
| Specific `s3:*` actions | DOCUMENTED | Hetzner says `s3:*` can be replaced with specific actions. |
| `Condition` | UNQUALIFIED | No Hetzner policy contract found that proves the condition dialect or evaluation. |
| `s3:prefix` for ListBucket | UNQUALIFIED | No Hetzner proof that prefix conditions enforce the required deny boundary. |
| `NotAction` | NOT SUPPORTED | Hetzner explicitly says it is accepted but has no effect. |
| Console listing after key restriction | REGRESSION EXPECTED | Hetzner warns its frontend may no longer list objects for restricted keys. |

Sources: [Hetzner S3 credentials](https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/),
[supported actions](https://docs.hetzner.com/storage/object-storage/supported-actions/),
and [buckets and objects](https://docs.hetzner.com/storage/object-storage/faq/buckets-objects/).

## Shared-bucket policy decision

`DenyAllUsersButOne` is **not applied**. On this bucket it would deny the
CNPG, Velero and Longhorn identities unless every required identity were
explicitly allowlisted, which is outside this qualification and could break
backup/restore. No policy was changed and no backup object was modified.

A proposed explicit `Deny` targeting only the Factory key for objects outside
`factory-checkpoints/v1/` cannot be accepted from the documented feature set:
it would require a proven `Condition`/`s3:prefix` or equivalent resource
negation semantics. Hetzner documents neither sufficiently for this use, and
`NotAction` cannot be used as a workaround. An `Allow` on the Factory prefix
would not remove the existing same-project broad rights.

Therefore the current decision is:

1. Do not alter the shared backup bucket policy.
2. Do not use the CNPG key as the Factory identity.
3. Do not claim IAM isolation for a same-project dedicated key unless a
   disposable policy test proves the exact deny behavior.
4. Keep Factory activation blocked until a dedicated key exists and the
   operator explicitly accepts either a proven policy or the documented
   project-wide residual risk.

The safer alternative remains a separate Hetzner project and bucket. That
would contradict the current V1 shared-bucket decision, so it is documented as
an alternative rather than created here.

## Effective permissions observed

The existing shared key was probed read-only, with counts only:

| Prefix | Effective result |
| --- | --- |
| `factory-checkpoints/v1/fixture/` | LIST allowed |
| `cnpg/` | LIST allowed, 21 objects at probe time |
| `velero/` | LIST allowed, 3 objects at probe time |
| `longhorn/` | LIST allowed, 1 object at probe time |

This is an observed IAM FAIL for Factory least privilege. The probe did not
read object bodies and did not PUT, DELETE or overwrite any CNPG, Velero or
Longhorn object. Because no policy was applied, existing backup identities
were not changed; their permissions are preserved by non-intervention, not
by a new isolation proof.

## Identity and ESO gate

Names-only Doppler inspection found the existing names:

- `HETZNER_S3_ACCESS_KEY_ID`
- `HETZNER_S3_SECRET_ACCESS_KEY`

The following names are still absent:

- `FACTORY_CHECKPOINT_S3_ENDPOINT`
- `FACTORY_CHECKPOINT_S3_REGION`
- `FACTORY_CHECKPOINT_S3_BUCKET`
- `FACTORY_CHECKPOINT_S3_PREFIX`
- `FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID`
- `FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY`
- `FACTORY_CHECKPOINT_INTERVAL_SECONDS`

No values were printed or copied. The next identity step belongs to the
external Hetzner/Doppler owner: create or supply a dedicated Factory key in
the existing project, then populate these seven names without reusing the
CNPG credential. Only after effective permission tests pass may a separate
GitOps PR add the dormant ExternalSecret to the active Kustomization.

## Disposable policy qualification required before activation

No disposable bucket or policy test environment was available to this run;
the shared bucket was not used for policy experiments. The required future
test must use a disposable bucket/environment or an owner-approved isolated
policy target and record response codes for:

1. Factory key: PUT/GET/LIST/DELETE under `factory-checkpoints/v1/fixture/`.
2. Factory key: read-only LIST outside the prefix denied.
3. Factory key: disposable outside-prefix GET/PUT/DELETE denied, if prefix
   isolation is claimed.
4. Existing CNPG, Velero and Longhorn identities: their required operations
   remain successful, using only non-destructive canaries and their existing
   backup mechanisms.
5. Policy rollback: the original shared-bucket policy is recoverable before
   any test against the real backup bucket.

If the owner chooses to accept the documented project-wide residual risk,
that acceptance must be explicit. It is not an IAM isolation PASS and it does
not justify applying `DenyAllUsersButOne` to the shared backup bucket.

## Restoration gate

`CLAIM_LOSS_RESTORE=NOT_EXECUTED`; no SandboxClaim was created, interrupted or
deleted. The drill remains blocked until all of the following are true:

- dedicated Factory key exists;
- seven Doppler names have values, checked by presence only;
- effective permissions are qualified;
- a separate ESO activation PR is reviewed and merged;
- the Secret is Ready and the Factory Pod has the seven variable names;
- a new disposable SandboxClaim has no live session or Work Item references.

Only then may the disposable drill capture a dirty Git workspace, simulate
loss of that claim, restore into a new claim, verify bytes/SHA-256/commit/tree,
test refusal and idempotence, and measure RPO/RTO. Until then:

| Evidence | Result |
| --- | --- |
| S3 transport | RUNTIME PASS, prior #631 evidence |
| Manifest/checksum/binding refusal | RUNTIME PASS, prior #631 evidence |
| Shared-key IAM isolation | RUNTIME FAIL |
| Dedicated-key policy qualification | NOT EXECUTED |
| ESO activation | BLOCKED |
| Claim-loss restore | NOT EXECUTED |
| RPO / RTO | UNKNOWN |
| Destructive GC | INACTIVE |

PLT-109 and PLT-24 remain open. PLT-105, fixtures #130/#134, active sessions,
CNPG, Velero and Longhorn objects remain untouched.

