# PLT-109 / PLT-24 checkpoint S3 qualification

Status: **prepared, not executed** (2026-10-21).

## Current boundary

`factory-platform` `origin/main` contains the Git bundle, manifest,
checksum, S3 adapter, isolated restore and claim-loss admission path. Its
static and synthetic evidence is separate from live evidence. `kube-ops`
currently has only the CNPG/Hetzner credential ExternalSecret in the
`mastra-factory` namespace; that Secret is not a Factory checkpoint identity.

The active cluster observes the private Hetzner backup bucket
`smadja-dev-homelab-backups`, with CNPG prefixes and shared Velero/Longhorn
usage. The proposed Factory bucket `smadja-dev-factory-checkpoints` does
**not** exist in the observed inventory. Provisioning belongs in
`homelab-infra`; this PR creates no Hetzner project, bucket, access key or
bucket policy.

### Security boundary: project first, prefix second

**V1 decision:** create a separate Hetzner Object Storage project for Factory,
with the dedicated private Factory bucket as its only bucket and a dedicated
Factory access key. Do not create this key in the existing backups project.
Hetzner confirms that **every key can access all buckets in its own project by
default**. A bucket-policy `Allow` on the new bucket does *not* revoke access
to the existing backup buckets if keys share the backup project.

Within the dedicated Factory project, `factory-checkpoints/v1/` is initially
an **object naming convention, not an independently enforced security
boundary**. The Factory key can be restricted to this prefix only if an
explicitly validated deny/allow policy, or a cross-project key with an explicit
allow grant, really enforces it. Do not claim prefix-level denial merely
because a policy lists a prefix under `Allow`.

An optional stricter design uses **different projects for the key and bucket**:
a credential project with no buckets, and the Factory bucket in its own project.
For such a cross-project grant, Hetzner documents a
`Principal: arn:aws:iam:::user/p<credential-project-id>:<access-key>`
bucket policy. Grant `s3:ListBucket` only with the required `s3:prefix`
condition and grant `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`
only on `arn:aws:s3:::smadja-dev-factory-checkpoints/factory-checkpoints/v1/*`.
**That `Allow`-only pattern is not sufficient for a key in the bucket's own
project.** Choose the additional project only if strict prefix isolation is
actually required; don't add a second project to satisfy an untested checklist.

The Factory adapter uses PutObject, GetObject, ListObjectsV2 and DeleteObject;
its manifest is the commit point: the bundle is uploaded first, then the
manifest. An incomplete upload is not evidence of a recoverable checkpoint.
Do not activate destructive GC just because the key has DeleteObject rights.

Reference: https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/

**Required negative proof for V1:** with the Factory key, a *read-only* list of
`smadja-dev-homelab-backups` must be denied. Never issue a write or delete
against the production backups bucket to test isolation. Also confirm that the
Factory project contains no other buckets. If strict prefix isolation is
selected, additionally prove list/get/put/delete denial outside the prefix
*using only explicitly disposable canaries in the Factory bucket*. Failure of
any required negative test blocks runtime activation; record actual S3 response
codes, not a speculative policy PASS.

## Doppler → ESO → Factory wiring

The dormant manifest
`k8s/applications/platform/mastra-factory/checkpoint-s3-externalsecret.dormant.yaml`
maps these seven Doppler keys one-to-one into
`mastra-factory-checkpoint-s3`. The Deployment imports that Secret optionally
and reloads on change. Because the ExternalSecret is not in the active
Kustomization, missing credentials or a missing bucket cannot make Argo
degraded or activate checkpoint S3 accidentally. The Factory parser also
rejects a partial four-field connection configuration.

Activation is a separate reviewed change after all of the following are true:

1. `homelab-infra` has provisioned a separate Hetzner storage project and the
   private Factory-only bucket/key; confirmed the backup bucket cannot be listed
   by the new key. If strict prefix isolation was selected, also prove its
   separately configured bucket policy on disposable canaries.
2. The seven Doppler keys exist in `infrastructure/prd` (presence only; never
   print their values).
3. The dormant ExternalSecret is added to this Kustomization and Argo reports
   it `Ready`.
4. The Pod environment contains the seven variable names, with no values
   printed, and the application remains healthy.

## Disposable S3 fixture

Run only with the dedicated key and a unique timestamped capture ID. The
fixture is `tests/fixtures/recovery/factory-checkpoint-s3-qualification.yaml`.
The operator must record only object keys, HTTP/S3 status codes, byte counts,
SHA-256 values of the disposable bundle, and elapsed durations.

Required sequence:

1. Upload a small synthetic bundle to
   `factory-checkpoints/v1/fixture/<capture-id>.bundle`.
2. Read it back, compare byte count and SHA-256, and verify the exact content.
3. Upload the JSON manifest second; verify schema version, capture ID,
   session/work-item/repository/branch binding, bundle key, size and digest.
4. List only the fixture prefix and confirm both objects are visible.
5. Assert the Factory key cannot list the existing shared backups bucket
   (read-only check, do not read object contents or mutate any backup).
   For a separately chosen strict-prefix policy, also assert denial of
   list/get/put/delete outside the prefix **only on disposable Factory objects**.
6. Delete only the two disposable fixture objects and verify they are absent.

The fixture is not a Factory runtime checkpoint and cannot promote GC or
claim-loss recovery. A live run is `NOT_EXECUTED` until all six steps pass
with the dedicated policy. Do not use a production session, a PLT-105 volume,
or the #130/#134 fixture resources.

## Controlled SandboxClaim disappearance exercise

This is a separately approved, strictly disposable drill. Create exactly one
new uniquely labelled `SandboxClaim` in `mastra-sandbox`, bind it to a new
throwaway workspace, write one sentinel file, and capture it through the
Factory path. Before any interruption, prove that no active Factory session,
Work Item, pending start, or live workspace references the claim. Record the
claim UID and the checkpoint manifest key without reading Secret values.

Only then may the operator simulate disappearance of that disposable claim.
The replacement claim must restore into a new empty workspace, verify bundle
SHA-256, commit SHA, tree SHA and binding, and leave the original production
namespaces untouched. If any stop condition in the fixture is met, stop and
retain evidence; do not create a replacement claim. Delete only the drill
claim/PVC and the disposable S3 objects after the evidence is captured.

No claim-loss exercise is authorized by this PR. The current result remains
`CLAIM_LOSS_RESTORE=NOT_EXECUTED`.

## RPO / RTO and GC gates

RPO is measured from the last successful workspace mutation to the completed
manifest upload. RTO is measured from the observed claim disappearance to a
new Ready workspace whose sentinel and Git identities verify. Use monotonic
timestamps and record seconds with the fixture result. Until a live run is
complete:

| Measure | Result |
| --- | --- |
| S3 upload/download | `NOT_EXECUTED` |
| claim-loss restore | `NOT_EXECUTED` |
| RPO | `UNKNOWN` |
| RTO | `UNKNOWN` |
| destructive GC | `INACTIVE` |

The existing Factory retention primitive remains unwired. Do not enable
deletion until active recovery references, grace period, orphan handling and
negative live-reference protection have been proven in a separate review.

## Evidence levels

- **STATIC:** dormant ESO mapping, optional Deployment import, fixture and
  policy contract render successfully.
- **SYNTHETIC:** Factory main's local bundle/manifest/checksum and mock-store
  tests only; no S3 or deployed claim-loss conclusion.
- **RUNTIME:** currently `NOT_EXECUTED` for S3 and claim-loss; RPO/RTO remain
  `UNKNOWN`.
- **USER:** not in scope.

The machine-readable handoff is
`docs/operations/plt-109-plt-24-checkpoint-s3-test-result-2026-10-21.json`.
