# Workflow-integrity: owner admission (PLT-56)

## One-time owner bootstrap

This PR changes protected `.github/workflows/*` and `.github/actions/*` paths.
It **must fail** the existing workflow-integrity gate and **cannot authorize
itself**. The repository owner must review the changes and use GitHub's
explicitly permitted administrative bootstrap procedure. Never silently
disable the check or claim it passed.

## Workflow contract

- `pull_request_target` checks out **only** the trusted base SHA. It never runs
  Python, JavaScript, shell scripts, or test harnesses from the untrusted PR.
  Head code is used solely as inert Git diff and JSON input.
- Permissions stay `contents: read` and `pull-requests: read`.
- After bootstrap, the owner (`SmadjaPaul`) creates a separate same-repository
  PR editing **only** `.github/workflow-integrity-admissions.json`. The gate
  checks the GitHub-authenticated PR author and validates the proposed registry
  document as data, without executing it.
- Each entry contains `repository`, `pr`, 40-character `headSha`, exact
  `paths`, `reason`, `approvedBy: SmadjaPaul` and `expiresAt` in UTC.
  Expiration must be within seven days at the time the registry PR is checked.
- Protected PRs may be admitted **only using registry content on the base
  branch** and the exact current SHA and *complete protected path set*.
  No globs, forks, expired records, registry edits in the same PR, or changes
  to the gate workflow or its verifier/tests under
  `.github/actions/workflow-integrity/` can be admitted. Any change to the
  gate implementation requires another explicit owner bootstrap.
- A new HEAD commit invalidates the old record.
- After the owner's registry PR merges, trigger a **new**
  `pull_request_target` event for each affected PR (for example close/reopen).
  Rerunning an old job may reuse its old base SHA and cannot prove admission.
- Remove admission records via a separate owner-only registry PR after
  the protected PRs merge. All other CI checks, branch protections,
  requirements, Atlantis and recovery gates remain in effect.

`approvedBy` is a human-readable audit statement, **not a signature**.
The actual owner-authentication signal for registry changes is the GitHub PR
author, checked against the expected owner, plus same-repo/single-file scope.
Retain normal branch review and merge protections.

## Example record (replace all placeholders before opening the registry PR)

```json
{
  "schemaVersion": 1,
  "admissions": [
    {
      "repository": "SmadjaPaul/kube-ops",
      "pr": 949,
      "headSha": "REPLACE_WITH_EXACT_40_CHARACTER_HEAD_SHA",
      "paths": [
        "tests/harness/atlantis-plan-only-test.sh",
        "tests/harness/backup-audit-contract-test.sh"
      ],
      "reason": "PLT-56 owner-authorized audit contract changes",
      "approvedBy": "SmadjaPaul",
      "expiresAt": "REPLACE_WITH_UTC_WITHIN_SEVEN_DAYS"
    }
  ]
}
```

The workflow runs standard-library unit tests **from the base checkout**:
`python3 -m unittest discover -s .github/actions/workflow-integrity -p 'test_*.py'`.

## Trust boundary and manual approval limitations

The registry check authenticates the **GitHub PR author account**, not a
separate human approval. If an automation or connected app can create PRs using
the same `SmadjaPaul` identity, author equality alone cannot distinguish the
owner from that automation. Therefore:

- The repository owner must independently review and decide on the bootstrap
  merge and every registry-admission merge using GitHub's owner-controlled
  administrative process.
- Required status checks and branch rules must be independently verified; no
  CODEOWNERS requirement or ruleset is established by this PR. If admission
  records can be pushed directly to `main` by an untrusted actor, the
  gate cannot be considered owner-authorized.
- Do not enable automatic merging of admission-registry PRs. Avoid granting
  agents or other applications write authority to owner-admission records.
- This gate cannot validate the correctness of a protected test change; it only
  provides narrowly scoped owner admission once the separate authorization
  and repository protections have been established.

Protected-file rename detection must be fail-closed: the verifier uses
`git diff --no-renames` so that both the deletion of a protected source
and creation of its new path are included in the changed-file set.

## PLT-56 protected path scope (revalidate SHA before each admission)

| PR | Protected paths |
| --- | --- |
| #947 | `tests/harness/longhorn-offsite-pvc-contract-test.sh` |
| #948 | `tests/harness/velero-storage-tier-test.sh` |
| #949 | `tests/harness/atlantis-plan-only-test.sh`, `tests/harness/backup-audit-contract-test.sh` |

Each registry entry must use the **current** exact HEAD SHA of its PR.
An admission for #947 does not constitute approval to remove the Longhorn
global recurring job; the 19 primary-coverage gaps still need a separate
recoverability decision.

## Boundaries

This mechanism admits changes to protected code paths; it does **not**
guarantee backup correctness. PLT-56 #947 must remain NO-GO until the 19
primary-backup gaps are qualified without losing irreplaceable data.
No cluster, S3, Atlantis or Proxmox runtime mutation is authorized.
