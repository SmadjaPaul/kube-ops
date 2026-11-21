# Post-merge verification and automatic revert (PLT-390 lot 3)

Decision (Paul, 20/11/2026): after a merge that touches an app, wait for the production to be reconciled at that commit, run `just app-test APP NAMESPACE --phase runtime --cluster homelab`, and, when the deployment itself is broken, open a `git revert` PR in auto-merge and notify through ntfy. Rules of revert come from PLT-141.

## Chain

1. `scripts/post-merge-affected.sh SHA`: files of the commit to apps. `k8s/applications/<domain>/<app>/**` gives app `<app>`, Argo Application `apps-<domain>` (one Application per domain directory), namespace from the kustomization. Documentation is ignored. Everything else (domain-level files, `platform`, infrastructure, optional, policy, scripts, tests, workflows) is OTHER.
2. `scripts/verify-revision.sh ARGO_APP SHA`: `status.sync.revision` contains the commit, `Synced`, `Healthy`, last operation not `Running`/`Failed`/`Error`. Evidence level RECONCILED. Timeout at most 600 s, then FAIL. The orchestrator passes `--allow-unhealthy`: it still waits for `Healthy`, but at the deadline a `Synced` Application whose last operation `Succeeded` at the commit proves the revision (`HEALTH=<status>` printed). Argo health is aggregate over the domain Application, so it does not gate the proof; a broken deploy (CrashLoop, bad image) reaches `app-test` runtime, whose FAIL leads to REVERT. A sync failure or a revision never reached stays NOT_PROVEN, hence NOTIFY.
3. `just app-test` (lot 1): `CHECK ...` lines then `APP_TEST=PASS|FAIL|BLOCKED`. Evidence level RUNTIME.
4. `scripts/lib/post-merge-decision.sh`: `NONE`, `NOTIFY`, `REVERT` or `ESCALATE`.
5. `scripts/post-merge-revert.sh`: branch `claude/post-merge-revert-<sha12>`, PR labelled `post-merge-revert`, auto-merge squash, trailer `Post-merge-revert-of: <sha>`.
6. `scripts/post-merge-notify.sh`: ntfy; in the runner pod the URL comes from the cluster Secret `monitoring/alertmanager-ntfy-url`, elsewhere from Doppler through `doppler-safe.sh`.

## Decision table

| Situation | Decision |
|---|---|
| no app touched | NONE |
| revision not proven in 10 min (any verdict) | NOTIFY, no revert |
| `APP_TEST=PASS` | NONE |
| `APP_TEST=BLOCKED` or recipe absent | NOTIFY, no revert |
| `FAIL` but `DEPLOY_HEALTH` is not `FAIL` (golden-path debt: oidc, network, backup, exposure, observability, renovate; or `selfheal` "aucun pod", no workload) | NOTIFY `golden_path_fail_no_revert`, failing check ids in the message, no revert |
| `FAIL` with `DEPLOY_HEALTH=FAIL`, commit touches more than apps | ESCALATE, no revert |
| `DEPLOY_HEALTH=FAIL`, newer commit touches the same app | ESCALATE, no revert |
| `DEPLOY_HEALTH=FAIL`, a revert of this commit already exists | ESCALATE (one revert, then escalation) |
| `FAIL` on a commit that is itself a revert | ESCALATE (never a revert of a revert) |
| `DEPLOY_HEALTH=FAIL`, an affected app has a PVC or a CNPG Cluster | ESCALATE `stateful_app_no_auto_revert` (`verify-migration`): the revert does not undo a migration, Paul decides (PLT-398) |
| `DEPLOY_HEALTH=FAIL`, otherwise | REVERT |

`DEPLOY_HEALTH=PASS|FAIL|UNKNOWN` is printed by `app-test` (runtime) from the `selfheal` check: `FAIL` only for pods not Ready or recent restarts (pods `Failed`/Evicted and pods being deleted are ignored) (after exceptions and ratchet); `UNKNOWN` for no pod, scale to zero, BLOCKED. The runtime ratchet freezes only static debt, so the other checks cannot gate a revert. With several apps, one `FAIL` is enough.

The revert restores manifests only. It does not restore data or undo a migration: the PR body and the ntfy message say so.

## Reliability rules (PLT-398)

- `verify-revision.sh` runs `git fetch origin` when the Application revision or the commit is missing from the clone (main moves on during the wait). All waits share one global deadline (`--timeout`, passed as `--deadline`); one wait per Argo Application, shared by the apps of a domain.
- The loop guards read through a read-only `GITHUB_TOKEN` (`pull-requests: read`). A failing `gh` is `GUARD_UNKNOWN` and fails safe (treated as already reverted / a revert: ESCALATE). The revert commit itself carries the trailer `Post-merge-revert-of: <sha>`.
- Files of every commit of the push (`github.event.before..sha`) count, not only the tip (`post-merge-affected.sh SHA BASE`).
- Job `alert`: ntfy `urgent` when `verify`, `revert` or `announce` failed or was cancelled.

## Identities and RBAC

No Doppler token and no kubeconfig in GitHub or in the workflow. The `verify` and `announce` jobs run on an ARC runner inside the cluster (scale set `kube-ops-ci-arc`, `k8s/optional/github-actions-arc-kube-ops`) with the pod's own ServiceAccount `arc-runners-kube-ops/kube-ops-post-merge`. `scripts/kubectl-ro.sh` runs in in-cluster mode there (`KUBECTL_RO_IN_CLUSTER=1`): no preflight, no Doppler, and the effective identity must be exactly that ServiceAccount. All read filters of the wrapper stay.

Rights (`rbac.yaml`, get/list only; no watch, create, update, patch, delete, exec, logs):

| Scope | Resource | Verbs | Used by |
|---|---|---|---|
| cluster | `namespaces` | get | app-test |
| cluster | `pods`, `services`, `persistentvolumeclaims` | get, list | app-test |
| cluster | `httproutes.gateway.networking.k8s.io` | get, list | app-test |
| cluster | `clusters.postgresql.cnpg.io`, `backups.postgresql.cnpg.io` | get, list | app-test |
| cluster | `scaledobjects.keda.sh` | get, list | app-test |
| `argocd` | `applications.argoproj.io` | get | verify-revision |
| `velero` | `backups.velero.io` | get, list | app-test |
| `monitoring` | `services/proxy` named `kube-prometheus-stack-prometheus:9090` | get | app-test |
| `monitoring` | `secrets` named `alertmanager-ntfy-url` | get | ntfy |

The only Secret is the ntfy publish URL. ntfy.sh topics have no authentication: the topic in the URL is the secret, so it stays a cluster Secret (External Secrets from Doppler, `alertmanager-secrets.yaml`) readable under one `resourceName`, never a GitHub variable or secret. The runner registers with GitHub through the existing ARC GitHub App (`arc-github-app`, copied by External Secrets from Doppler like the other scale sets); no new registration secret. Tools missing from the stock runner image (kubectl, jq, yq, just) are installed by `scripts/ci-install-tools.sh` with pinned versions and sha256.

Egress (CiliumNetworkPolicy, default deny): DNS, GitHub, Kubernetes API, `dl.k8s.io`, `ntfy.sh`, `cloudflare-dns.com`, and the Cloudflare edge ranges on 443 (the public probe of app-test pins the address with `curl --resolve`).

## Gestures of Paul (all that remains)

1. ARC GitHub App installation: add `SmadjaPaul/kube-ops` to the installation of the existing ARC App (GitHub, Settings, Applications), as for `website`. Without it the scale set cannot register.
2. Revert bot, one-time: create the GitHub App `kube-ops-revert-bot`, installed on `kube-ops` only, permissions Contents read/write, Pull requests read/write, Metadata read. Then set `vars.REVERT_BOT_APP_ID` and `secrets.REVERT_BOT_PRIVATE_KEY` (the one external identity: only a GitHub App can write to `main` and start the required checks; `GITHUB_TOKEN` cannot, and `AGENT_GITHUB_TOKEN` is a personal admin token).
3. Switch: set `vars.POST_MERGE_VERIFY_ENABLED=true` once the scale set is Healthy and the App exists.

Nothing else: no Doppler token, no kubeconfig, no ntfy URL in GitHub. The repository already allows auto-merge and squash; the required checks stay in force on the revert PR. The workflow runs on `push` to `main` only, never on PR code (the repository is public).

## Evidence

Contract tests: `tests/harness/verify-revision-test.sh`, `post-merge-decision-test.sh`, `post-merge-verify-test.sh`, `post-merge-revert-test.sh`, `tests/agent-guard/kubectl-ro-in-cluster-test.sh`. `just post-merge-verify --dry-run SHA` shows the decision and the revert plan without creating a PR or sending ntfy.
