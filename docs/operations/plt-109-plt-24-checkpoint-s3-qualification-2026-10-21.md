# PLT-109 / PLT-24 checkpoint S3 qualification

Status: **prepared, not executed** (2026-10-21).

## Current boundary

`factory-platform` `origin/main` contains the Git bundle, manifest,
checksum, S3 adapter, isolated restore and claim-loss admission path. Its
static and synthetic evidence is separate from live evidence. `kube-ops`
currently has only the CNPG/Hetzner credential ExternalSecret in the
`mastra-factory` namespace; that Secret is not a Factory checkpoint identity.

The active cluster observes one private Hetzner backup bucket,
`smadja-dev-homelab-backups`, with CNPG prefixes such as `cnpg/mastra-factory`
and shared Velero/Longhorn usage. Reusing its shared identity would exceed
least privilege. The intended storage contract is a private Factory-only
bucket (or a separately policy-isolated project) with the object prefix
`smadja-dev-factory-checkpoints` with the object prefix
`factory-checkpoints/v1/`. This bucket is a proposed dedicated target; it is
not observed in the current runtime inventory. Bucket creation and key policy belong to
`homelab-infra`; this repository contains no Terraform/OpenTofu for it.

The policy must allow only the Factory key to operate on the checkpoint
objects and must constrain listing to the checkpoint prefix. The Factory
adapter needs `PutObject`, `GetObject`, `ListObjectsV2` and `DeleteObject`.
The manifest is the commit point: upload the bundle first, then the manifest.
An incomplete bundle or manifest is not recoverable.

The minimum policy shape is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListFactoryCheckpointPrefix",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam:::user/p<credentials-project>:<factory-key>"},
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::smadja-dev-factory-checkpoints",
      "Condition": {"StringLike": {"s3:prefix": ["factory-checkpoints/v1", "factory-checkpoints/v1/*"]}}
    },
    {
      "Sid": "FactoryCheckpointObjects",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam:::user/p<credentials-project>:<factory-key>"},
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::smadja-dev-factory-checkpoints/factory-checkpoints/v1/*"
    }
  ]
}
```

The `<credentials-project>` and `<factory-key>` placeholders are provisioned
outside Git. The negative fixture cases must prove that this key cannot list,
read, write or delete outside the prefix.

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

1. `homelab-infra` has provisioned a private bucket and a reviewed policy for
   a dedicated access key; the CNPG/Velero/Longhorn key is not reused.
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
5. Assert negative permissions for list/get/put/delete outside the prefix.
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
