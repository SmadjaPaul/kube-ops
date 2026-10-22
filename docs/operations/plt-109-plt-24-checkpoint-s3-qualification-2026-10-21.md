# PLT-109 / PLT-24 checkpoint S3 qualification

Status: **GitOps activation prepared; runtime fixture and claim-loss not executed** (2026-10-22).

## Current boundary

`factory-platform` `origin/main` contains the Git bundle, manifest,
checksum, S3 adapter, isolated restore and claim-loss admission path. Its
static and synthetic evidence is separate from live evidence. `kube-ops` now
activates the Factory checkpoint ExternalSecret through the existing
`doppler-cluster` store. The Factory Secret is still absent until Argo
reconciles the qualified GitOps change. Its two credential fields map
explicitly to the existing `HETZNER_S3_*` keys; no Secret values are read or
printed.

The active cluster observes the private Hetzner backup bucket
`smadja-dev-homelab-backups`, with CNPG prefixes and shared Velero/Longhorn
usage. V1 deliberately reuses that bucket under the dedicated object prefix
`factory-checkpoints/v1/`. This PR creates no project, bucket, access key or
bucket policy.

### Security boundary: shared bucket, dedicated key, proven policy

**V1 decision:** reuse `smadja-dev-homelab-backups` in `fsn1`; do not create a
new Hetzner project or bucket. Factory object keys use
`factory-checkpoints/v1/`; the Factory configuration value is
`factory-checkpoints/v1` without a trailing slash because the upstream parser
rejects a trailing slash.

Hetzner confirms that **every key can access all buckets in its own project by
default**. The V1 operator decision accepts temporary reuse of the existing
shared key to qualify transport quickly, while explicitly recording:
`IAM_ISOLATION=RUNTIME_FAIL — RISK_ACCEPTED_V1`. The prefix is therefore an
application namespace only, not an IAM boundary. No least-privilege claim is
made and no bucket policy is changed.

### Candidate same-bucket policy

The following is a policy candidate for the external Hetzner operator. It is
not applied by kube-ops and is not runtime proof. The principal and exact
Hetzner policy envelope must be supplied by the external owner:

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::smadja-dev-homelab-backups",
      "Condition": {"StringLike": {"s3:prefix": ["factory-checkpoints/v1", "factory-checkpoints/v1/*"]}}
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::smadja-dev-homelab-backups/factory-checkpoints/v1/*"
    }
  ]
}
```

Do not describe this `Allow` as restrictive until disposable canaries prove
denial outside the prefix and a read-only list of the shared bucket proves
the intended boundary. The V1 decision accepts the existing project-wide
rights as residual risk and keeps `IAM_ISOLATION=RUNTIME_FAIL — RISK_ACCEPTED_V1`.
Existing CNPG/Velero/Longhorn access must stay untouched.

The Factory adapter uses PutObject, GetObject, ListObjectsV2 and DeleteObject;
its manifest is the commit point: the bundle is uploaded first, then the
manifest. An incomplete upload is not evidence of a recoverable checkpoint.
Do not activate destructive GC just because the key has DeleteObject rights.

Reference: https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/

**Required negative proof for V1:** with the Factory key, a *read-only* list
outside `factory-checkpoints/v1/` in `smadja-dev-homelab-backups` must be
denied. Never issue a write or delete against CNPG, Velero or Longhorn objects
to test isolation. If the key has access to other buckets in the same project,
record that as residual risk. Failure of any required negative test blocks
runtime activation; record actual S3 response codes, not a speculative policy
PASS.

## Doppler → ESO → Factory wiring

The manifest
`k8s/applications/platform/mastra-factory/checkpoint-s3-externalsecret.dormant.yaml`
maps these seven Doppler keys one-to-one into
`mastra-factory-checkpoint-s3`. The Deployment imports that Secret optionally
and reloads on change. The checkpoint ExternalSecret is now in the active
Kustomization; its optional Deployment import still fails closed if the
provider is temporarily unavailable. The Factory parser also rejects a
partial four-field connection configuration.

Activation is a reviewed GitOps change after all of the following are true:

1. The existing HETZNER S3 key names and five non-secret Factory settings are
   present in Doppler `infrastructure/prd`; values are never printed.
2. `doppler-cluster` reports `Ready=True` and an existing Velero ExternalSecret
   proves the two HETZNER remote references resolve through that store.
3. The checkpoint ExternalSecret is added to this Kustomization and Argo
   reports it `Ready`.
4. The Pod environment contains the seven variable names, with no values
   printed, and the application remains healthy.

## Disposable S3 fixture

Run only with the accepted existing key and a unique timestamped capture ID. The
fixture is `tests/fixtures/recovery/factory-checkpoint-s3-qualification.yaml`.
The operator must record only object keys, HTTP/S3 status codes, byte counts,
SHA-256 values of the disposable bundle, and elapsed durations.

Required sequence:

1. Upload a small synthetic bundle to
   `factory-checkpoints/v1/fixture/<capture-id>.bundle`.
2. Read it back, compare byte count and SHA-256, and verify the exact content.
3. Upload the JSON manifest second; verify schema version, capture ID,
   session/work-item/repository/branch binding, bundle key, size and digest.
   Repeat the admission check with a wrong session, repository, branch and
   Work Item association; each must be refused before restore.
4. List only the fixture prefix and confirm both objects are visible.
5. Assert the Factory key cannot list other buckets in the existing project
   (read-only check, do not read object contents or mutate any backup).
   For a separately chosen strict-prefix policy, also assert denial of
   list/get/put/delete outside the prefix **only on disposable Factory objects**.
6. Delete only the two disposable fixture objects and verify they are absent.

The fixture is not a Factory runtime checkpoint and cannot promote GC or
claim-loss recovery. A live run is `NOT_EXECUTED` until all six steps pass
with the accepted shared-key risk recorded. Do not use a production session,
a PLT-105 volume,
or the #130/#134 fixture resources. Delete only objects below
`factory-checkpoints/v1/fixture/`.

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
timestamps and record seconds with the fixture result. Until a complete
Factory claim-loss run is complete:

| Measure | Result |
| --- | --- |
| S3 disposable transport (shared key only) | `RUNTIME_PASS` |
| S3 effective prefix isolation | `RUNTIME_FAIL` |
| claim-loss restore | `NOT_EXECUTED` |
| RPO | `UNKNOWN` |
| RTO | `UNKNOWN` |
| destructive GC | `INACTIVE` |

The existing Factory retention primitive remains unwired. Do not enable
deletion until active recovery references, grace period, orphan handling and
negative live-reference protection have been proven in a separate review.

## Evidence levels

- **STATIC:** active ESO mapping, optional Deployment import, fixture and
  candidate policy contract render successfully.
- **SYNTHETIC:** Factory main's local bundle/manifest/checksum and mock-store
  tests only; no S3 or deployed claim-loss conclusion.
- **RUNTIME:** existing disposable S3 transport and binding refusal are `PASS`;
  effective prefix isolation is `FAIL`; post-merge ESO reconciliation and
  claim-loss remain `NOT_EXECUTED`; RPO/RTO remain `UNKNOWN`.
- **USER:** not in scope.

The machine-readable handoff for the static/shared-bucket amendment is
`docs/operations/plt-109-plt-24-checkpoint-s3-shared-bucket-test-result-2026-10-21.json`.

The subsequent live observations are recorded separately in
`docs/operations/plt-109-plt-24-checkpoint-s3-runtime-evidence-2026-10-21.md`
and
`docs/operations/plt-109-plt-24-checkpoint-s3-runtime-test-result-2026-10-21.json`.
The live transport fixture passed with the existing shared key, but effective
prefix isolation failed; claim-loss restore and RPO/RTO remain unexecuted and
unknown.
