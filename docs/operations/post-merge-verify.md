# Post-merge verification and automatic revert (PLT-390 lot 3)

Decision (Paul, 20/11/2026): after a merge that touches an app, wait for the production to be reconciled at that commit, run `just app-test APP NAMESPACE --phase runtime --cluster homelab`, and on `FAIL` open a `git revert` PR in auto-merge and notify through ntfy. Rules of revert come from PLT-141.

## Chain

1. `scripts/post-merge-affected.sh SHA`: files of the commit to apps. `k8s/applications/<domain>/<app>/**` gives app `<app>`, Argo Application `apps-<domain>` (one Application per domain directory), namespace from the kustomization. Documentation is ignored. Everything else (domain-level files, `platform`, infrastructure, optional, policy, scripts, tests, workflows) is OTHER.
2. `scripts/verify-revision.sh ARGO_APP SHA`: `status.sync.revision` contains the commit, `Synced`, `Healthy`, last operation not `Running`/`Failed`/`Error`. Evidence level RECONCILED. Timeout at most 600 s, then FAIL.
3. `just app-test` (lot 1): `CHECK ...` lines then `APP_TEST=PASS|FAIL|BLOCKED`. Evidence level RUNTIME.
4. `scripts/lib/post-merge-decision.sh`: `NONE`, `NOTIFY`, `REVERT` or `ESCALATE`.
5. `scripts/post-merge-revert.sh`: branch `claude/post-merge-revert-<sha12>`, PR labelled `post-merge-revert`, auto-merge squash, trailer `Post-merge-revert-of: <sha>`.
6. `scripts/post-merge-notify.sh`: ntfy through `ALERTMANAGER_NTFY_URL` (Doppler `cluster/prd`, injected by `doppler-safe.sh`).

## Decision table

| Situation | Decision |
|---|---|
| no app touched | NONE |
| revision not proven in 10 min (any verdict) | NOTIFY, no revert |
| `APP_TEST=PASS` | NONE |
| `APP_TEST=BLOCKED` or recipe absent | NOTIFY, no revert |
| `FAIL`, commit touches more than apps | ESCALATE, no revert |
| `FAIL`, newer commit touches the same app | ESCALATE, no revert |
| `FAIL`, a revert of this commit already exists | ESCALATE (one revert, then escalation) |
| `FAIL` on a commit that is itself a revert | ESCALATE (never a revert of a revert) |
| `FAIL`, otherwise | REVERT, plus `verify-migration` when the app has a PVC or a CNPG Cluster |

The revert restores manifests only. It does not restore data or undo a migration: the PR body and the ntfy message say so.

## Prerequisites (gestures of Paul, none done by the PR)

The workflow is inert until the repository variable `POST_MERGE_VERIFY_ENABLED=true`.

1. Cluster-read runner: no scale set serves `SmadjaPaul/kube-ops` today (existing ones: factory-platform, homelab-infra, website). Needed: an ARC scale set `kube-ops-ci-arc` (or a label in `vars.POST_MERGE_RUNNER`) with `jq`, `just`, `kubectl`, `doppler`, egress to the Kubernetes API, Doppler and ntfy, and the `agent-operator` read identity. The workflow runs on `push` to `main` only, never on PR code (the repository is public).
2. `secrets.DOPPLER_TOKEN`: a read-only service token limited to the secrets used here (`KUBERNETES_AGENT_OPERATOR_KUBECONFIG` and its SHA-256 in `infrastructure/prd`, `ALERTMANAGER_NTFY_URL` in `cluster/prd`).
3. Revert bot: no usable identity exists. `AGENT_GITHUB_TOKEN` is a personal admin token; `GITHUB_TOKEN` cannot be used (its PRs do not start the required checks, and PR creation by Actions is disabled). Create a GitHub App `kube-ops-revert-bot` installed on `kube-ops` only (Contents read/write, Pull requests read/write, Metadata read), then set `vars.REVERT_BOT_APP_ID` and `secrets.REVERT_BOT_PRIVATE_KEY`.
4. Repository already allows auto-merge and squash; the required checks stay in force on the revert PR.

## Evidence

Contract tests: `tests/harness/verify-revision-test.sh`, `post-merge-decision-test.sh`, `post-merge-verify-test.sh`. `just post-merge-verify --dry-run SHA` shows the decision and the revert plan without creating a PR or sending ntfy.
