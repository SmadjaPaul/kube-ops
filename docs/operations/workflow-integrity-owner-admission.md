# Workflow-integrity: owner admission (PLT-56)

## One-time owner bootstrap

This PR changes protected `.github/workflows/*` and `.github/actions/*` paths.
It **must fail** the existing workflow-integrity gate and **cannot authorize
itself**. The repository owner must review the changes and use GitHub's
explicitly permitted administrative bootstrap procedure. Never silently
disable the check or claim it passed.

## Owner-only bootstrap procedure (one-time)

**This is an owner-admin task, not an agent action.** Under the current
`main` rule, `workflow-integrity` is required even for admins and the
trusted-base version intentionally rejects modifications to itself. An
ordinary PR review or GitHub App acting as the owner cannot turn this failing
status into a passing check.

1. **Before changing any rule:** independently review this PR's exact
   five-file diff and SHA; verify `pull_request_target` policy for the
   public repository in GitHub Actions Policy Insights; inspect the existing
   required checks and record the original protection state. Ensure no other
   PR will merge automatically during the short bootstrap window.
2. In the GitHub repository's **Settings → Branches → protection for
   `main`**, the human owner may explicitly authorize a **one-time**
   change removing only `workflow-integrity` from required checks.
   Retain `v1-contract`, `docs-required`, strict/up-to-date requirements,
   and administrator enforcement. Do not disable the rule, enable force pushes,
   grant a bypass actor or weaken any other checks.
3. Check that this PR's HEAD is still the **reviewed** SHA and that the
   remaining required checks are green for that HEAD and current base.
   Merge this single PR normally; do not represent the pre-bootstrap
   `workflow-integrity` failure as a PASS.
4. **Immediately restore** `workflow-integrity` as a required check, and
   verify the complete branch rule including strict checks and
   `enforce_admins=true`. Confirm the new workflow files and empty registry
   on `main`; verify a subsequent PR runs the new trusted-base
   `workflow-integrity` job. If any step fails, stop all further admissions
   and restore the exact original rule immediately.
5. Registry-only admission PRs remain separate. Each requires a truly
   independent owner decision on current PR SHA and path set. A GitHub
   `PR_AUTHOR` value or `approvedBy` string alone is **not** that
   independent human authorization. Never enable auto-merge for the registry.

This procedure describes an explicit administrative exception requiring the
owner to execute it personally. It does **not** grant an agent permission to
change GitHub protection settings and it is not a durable bypass design.

## Workflow contract

- `pull_request_target` checks out **only** the trusted base SHA. It never runs
  Python, JavaScript, shell scripts, or test harnesses from the untrusted PR.
  Head code is used solely as inert Git diff and JSON input.
- Permissions stay `contents: read` and `pull-requests: read`.
- After bootstrap, the owner (`SmadjaPaul`) creates a separate same-repository
  PR editing **only** `.github/workflow-integrity-admissions.json`. The gate
  checks the GitHub-authenticated PR author and validates the proposed registry
  document as data, without executing it.
- Each entry contains `repository`, `pr`, a 64-character
  `changeFingerprint`, exact `paths`, `reason`, `approvedBy: SmadjaPaul` and
  `expiresAt` in UTC. The fingerprint is computed from the complete raw Git
  diff between the trusted base and PR head: every file's path, status,
  old/new mode and type, and old/new blob ID, including non-protected files.
  It does not normalize or discard changed-line positions.
  Expiration must be within seven days at the time the registry PR is checked.
  Existing owner-approved pre-cutover registry entries with a 40-character
  `headSha` (notably the active Polyfin #997 entry) remain accepted **only**
  for their original exact event HEAD SHA, repository, PR, paths and existing
  expiry; they do not gain fingerprint-based rebase stability. Both entry
  formats can coexist transiently. New PLT-56 admissions must use
  `changeFingerprint`; migrate or let legacy entries expire naturally rather
  than invalidate already admitted unrelated work during gate bootstrap.
- Protected PRs may be admitted **only using registry content on the base
  branch**, the current complete protected path set and the exact complete
  diff fingerprint.
  No globs, forks, expired records, registry edits in the same PR, or changes
  to the gate workflow or its verifier/tests under
  `.github/actions/workflow-integrity/` can be admitted. Any change to the
  gate implementation requires another explicit owner bootstrap.
- A merge or rebase of `main` does not invalidate the record when the affected
  files' base/head blobs and raw metadata are unchanged. Any protected-file
  content change, protected file addition/deletion, or non-protected-file
  change changes the fingerprint and invalidates the record. The trusted base
  must be an ancestor of the PR head; stale branches fail closed.
- After the owner's registry PR merges, trigger a **new**
  `pull_request_target` event for each affected PR (for example close/reopen).
  Rerunning an old job may reuse its old base SHA and cannot prove admission.
- Registry size: at most 32 **unexpired** admissions (`expiresAt` in the future)
  and at most 64 entries in total, expired ones included. Expired entries are
  still fully validated but no longer count toward the 32 cap, so the registry
  purges itself. Changing these limits is a gate change (owner bootstrap).
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
      "changeFingerprint": "REPLACE_WITH_EXACT_64_CHARACTER_DIFF_FINGERPRINT",
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

## Public-repository Actions policy (December 2026)

GitHub's [secure use guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)
announces enforcement of the default `pull_request_target` event policy for
affected public repositories on **2026-12-02**. This repository is public.
The owner must verify the repository's Actions event policy and ensure the
trusted-base workflow remains authorized before that date. The connector cannot
read or change the event policy; do not infer that it is already configured.

Do not replace `pull_request_target` by `pull_request` as a quick fix:
a PR-controlled workflow could then edit the very gate that should check it.
If switching event models, design a separate trusted evaluator and verify its
protected status context independently.

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

## PLT-56 protected path scope (recompute fingerprint before each admission)

| PR | Protected paths |
| --- | --- |
| #947 | `tests/harness/longhorn-offsite-pvc-contract-test.sh` |
| #948 | `tests/harness/velero-storage-tier-test.sh` |
| #949 | `tests/harness/atlantis-plan-only-test.sh`, `tests/harness/backup-audit-contract-test.sh` |

Each registry entry must use the **current complete-diff fingerprint** computed
against the trusted base of its PR. The PR number and repository remain exact
identity fields; the last commit SHA is not used as the admission key, so a
strict-branch-protection synchronization can preserve the admission when the
reviewed change itself is unchanged.
An admission for #947 does not constitute approval to remove the Longhorn
global recurring job; the 19 primary-coverage gaps still need a separate
recoverability decision.

## Boundaries

This mechanism admits changes to protected code paths; it does **not**
guarantee backup correctness. PLT-56 #947 must remain NO-GO until the 19
primary-backup gaps are qualified without losing irreplaceable data.
No cluster, S3, Atlantis or Proxmox runtime mutation is authorized.
