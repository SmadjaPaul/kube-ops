# AGENTS.md — kube-ops

Git is the Kubernetes desired-state authority and Argo CD reconciles it continuously. Runtime tools provide evidence and, inside the Safety scope, execute changes; every durable runtime change is reconciled into Git.

## Authority

Active decisions live only in homelab-infra [docs/decisions.md](https://github.com/SmadjaPaul/homelab-infra/blob/main/docs/decisions.md) (D-2026-11-14-01). Read it at session start; it wins over this file, older tickets and docs. Do not copy decisions here.

Then: repository contracts and tests > this file > desired-state code > runtime as observed evidence. Runtime drift never silently becomes desired state.

Boundary: homelab-infra owns the Proxmox/Talos substrate, UniFi/LAN DNS, Cloudflare account/edge, Doppler bootstrap, Migadu, N100 and all OpenTofu. kube-ops owns Kubernetes/Argo desired state after the kubeconfig handoff and contains no Terraform/OpenTofu.

## Read order

This file → one skill from the table → only the application or infrastructure subtree you change. Run `just inventory` before you crawl the repository. Read `docs/state/cluster-reality.md` only for runtime questions (what runs, real CPU/RAM, exposure, data class); regenerate it with `bash scripts/cluster-reality.sh`. Rules for files under `k8s/` live in `k8s/CLAUDE.md`.

| Task | Entry |
|---|---|
| unfamiliar repository | `.agents/skills/repo-navigation` |
| add a service | `.agents/skills/deploy-a-service` |
| retire a service | `docs/operations/service-onboarding.md` |
| Argo sync/health; deliver on homelab or oracle-a1 | `.agents/skills/argocd-debug` |
| Kubernetes workload failure | `.agents/skills/kubernetes-debug` |
| runtime or post-merge proof | `.agents/skills/runtime-observer` |
| Cilium policy drops | `.agents/skills/cilium-hubble` |
| OIDC/Authentik | `.agents/skills/oidc-integration` |
| backup/restore | `.agents/skills/backup-restore` |
| incident triage | `.agents/skills/sre-triage` |
| cluster state from Grafana Cloud (homelab, oracle-a1) | `.agents/skills/observability` |
| ticket start/end memory (Hindsight MCP configured) | `.agents/skills/agent-memory` |
| resume a mission with no memory (compaction, interruption, model change) | `python3 scripts/mission/resume.py <mission-key>` (state `missions/backstage-pilote-canari.state.json` for the pilot; mission commits carry `Mission-Key`, `Mission-Step`, `Mission-Attempt` trailers) |

`.agents/` is the single agent knowledge tree; Claude reaches it through the `.claude/skills` symlink.

## Command surface

- `just check`: canonical local gate for every desired-state change. Run `kustomize build --enable-helm` on each changed path. `just check` = `npm run check:local`: the npm sub-checks and the bash tests of `scripts/check-bash-tests.list` run in parallel (`scripts/run-checks-parallel.mjs`, `CHECK_JOBS` to tune, output grouped per test, summary sorted by duration). Roots are rendered once and shared through `scripts/lib/render-cache.sh` (cache `~/.cache/kube-ops/render`, invalidated by any change under `k8s/`; use `render_root` instead of a direct `kustomize build --enable-helm` in a check). A new bash test must use `mktemp`, no fixed port, no write into the repository. CI runs `npm run check` (same sub-checks, narrowed by `V1_CONTRACT_ROOTS`) plus dedicated workflow steps; `just check-affected` stays the quick path for a diff.
- Kyverno step of `just check` (`scripts/policy-check.sh`): policies in `k8s/infrastructure/security/policies/platform-baseline.yaml` and `policy/static/repo-contract.yaml`, ratchet `policy/baseline.tsv`. A new violation fails; fix the manifest, never extend the baseline. After fixing existing ones, run `just policy-baseline-update`.
- `just verify-delivery CLUSTER APP`: post-merge PASS/FAIL from Grafana Cloud for `homelab` or `oracle-a1`; `just scaffold-oke-app`: OKE overlay + Application.
- `just inventory`: Git-only active imports and dormant candidates (not runtime evidence).
- `just kube-access-check`, `just runtime-inventory`, `just runtime-smoke`, `just status-app <app>`, `just diagnose-app <app>`, `just backup-audit`, `just e2e-list`.
- `bash scripts/kubectl-ro.sh [--cluster homelab|oracle-a1] <get|describe|logs|top|events|api-resources|version> ...`: read-only kubectl; `get --raw` admits the Prometheus/Loki query APIs and, for `scripts/app-status.sh` (app status JSON, `docs/platform/app-status.md`), a plain GET through the service proxy of a `svc-*` namespace (the `agent-operator` Role `agent-operator-monitoring-query` grants `get` on the service proxy of `kube-prometheus-stack-prometheus:9090` and `loki-gateway:80` only). On homelab it uses the limited `agent-operator` ServiceAccount (RBAC enforces: no Secret data) when its kubeconfig is distributed and valid, else falls back to the operator copy with a warning on stderr; `KUBECTL_RO_IDENTITY=auto|agent|operator` (default `auto`; `agent` refuses the fallback, `operator` is the legacy rollback). `bash scripts/kubectl-ro.sh [--cluster ...] auth whoami` prints the effective identity (no secret). Tokens are issued for 24 h by Paul with `AGENT_TOKEN_DURATION=24h bash scripts/agent-operator-token.sh --provision` (homelab) or `scripts/agent-operator-oke-token.sh --provision` (oracle-a1).
- `bash scripts/kubectl-rw.sh [--dry-run] <patch|scale|restart|undo|set-image|suspend|resume|delete|apply> <namespace> <target> [arg]`: bounded writes with the `agent-operator` identity (PLT-237), admitted namespaces in `k8s/infrastructure/security/agent-operator/scope.tsv`. If its kubeconfig is not distributed (`scripts/agent-operator-token.sh --provision`), stay read-only and repair through Git.
- `bash scripts/argo-terminate-stuck-sync.sh APP [MIN_AGE] [--dry-run]`: ends a sync stuck on hooks/health; it refuses when a PVC, PV, CNPG Cluster, ObjectStore or VolumeSnapshot would be pruned. Check first that the Application is in the admitted scope.
- `bash scripts/doppler-safe.sh <names|has|set|delete|run>`: the only Doppler entry point. `run` requires `--only KEY[,KEY...]` (only those secrets are injected, never the whole config); projects/configs are a closed list (Doppler projects `infrastructure`, `cluster`, `apps`, config `prd` only). Example: `bash scripts/doppler-safe.sh run --only LINEAR_API_KEY -- <cmd>`.

Every kubectl call goes through `scripts/lib/kube-preflight.sh` (the wrappers do it).

## Cluster access

`scripts/lib/kube-preflight.sh` materializes the canonical kubeconfig from Doppler (`KUBERNETES_OPERATOR_KUBECONFIG` + `KUBERNETES_OPERATOR_KUBECONFIG_SHA256`), verifies fingerprint and TLS, and removes it on exit. It ignores ambient kubeconfigs. If access fails: run `just kube-access-check`; authenticate Doppler if needed; otherwise recover the copy with `just kube-access-sync` in homelab-infra. Never ask Paul for a kubeconfig and never write `~/.kube/config`.

## Safety

Maximum autonomy (D-2026-11-15-03, in the homelab-infra decision journal; it replaces the per-operation approvals of D-2026-11-13-01 and D-2026-11-14-02 to -06): decide and execute through to runtime. Every mutation keeps three obligations: admitted scope with the limited identity, runtime verification with its evidence level, same-day Git reconciliation (branch → `just check` → PR → merge → Argo). For an Argo app with selfHeal, merge the Git change first. A ticket is done when the result works: verify, then fix or roll back.

Ask Paul only for a permanent limit (unrecoverable loss of unique personal data; his identity or presence, a purchase or a consent; uncontrolled spending; a provider access protection) or a real technical impossibility.

Kept protections: never the only copy of irreplaceable data (copy to R2 first, verified backup before deletion); admin path (cluster access, Cilium/Gateway reachability: test recovery access before removal); quotas and budgets; thermal limits; no secret shown, committed or logged; never disable a desired app to turn Argo green.

Absolute bans: `--admin` or any check/protection bypass; a disabled required check; disabled TLS (`--insecure-skip-tls-verify`, `-k`); a secret value shown to the agent, printed or committed, including Kubernetes Secret data (the sanctioned helpers, `scripts/lib/kube-preflight.sh` and `scripts/doppler-safe.sh`, use values without displaying them); `device_bash` and the Mac Linux VM; OpenTofu outside ARC. The Argo MCP stays read-only. If a command is refused, add it to the paul-unblock script of homelab-infra and continue.

Secret output (enforced by `.claude/hooks/secret-output-guard.py`): use `scripts/doppler-safe.sh` instead of `doppler secrets`; list environment names only (`env | cut -d= -f1`); `kubectl get secret` only with `-o name`, `kubectl describe secret` for keys; no `kubectl -v=6` or higher. Redirecting stdout does not hide stderr.

Branches: your own claude/ or codex/ prefix, never another agent's branch.

Process: D-2026-11-15-06 (homelab-infra docs/decisions.md).

## Evidence

`STATIC` < `CI` < `RECONCILED` (Argo Synced at the desired revision) < `RUNTIME` (workload, EndpointSlice, Gateway, DNS, TLS work) < `USER`. A merged PR proves no runtime level. Every PR body lists checks run with result and checks not run with reason; a missing check is never a pass. A stateful workload is incomplete without backup coverage; data that matters is incomplete until one restore is proven.

## Communication (STE80)

Reports, handoffs, Linear comments and PR descriptions follow STE80 ([full text](https://github.com/SmadjaPaul/Atlas/blob/main/policies/communication-style.md)). Reports to Paul are in French, conclusion first, then evidence; never conclude beyond the evidence. Statuses: `PASS`, `FAIL`, `BLOCKED`, `NOT_TESTED`, `NOT_PROVEN`. Handoff fields: `Objective`, `Status`, `Changes`, `Evidence`, `Blockers`, `NextAction`. Keep code, identifiers, logs and machine contracts verbatim.

## Context discipline

Load this file, one skill, one app tree and bounded runtime evidence. If a normal task needs more, improve navigation or scripts instead of writing a larger document.
