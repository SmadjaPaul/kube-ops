# AGENTS.md — kube-ops operating router

Read `docs/state/cluster-reality.md` only when the task touches the runtime (what runs, real CPU/RAM, exposure, data class, verdict); regenerate with `bash scripts/cluster-reality.sh`.

Git is the Kubernetes desired-state authority. Argo CD continuously reconciles Git. Runtime tools provide evidence and, within the per-operation rules in Safety, execute changes; every durable runtime change is reconciled into Git so the cluster never diverges from desired state.

## Authority

When sources disagree use: accepted repository contracts > this router > desired-state code > runtime as observed evidence. Runtime drift never silently becomes desired state.

Repository boundary:
- `homelab-infra`: Proxmox/Talos substrate, UniFi/LAN DNS, Cloudflare account/edge, Doppler bootstrap, Hetzner, Migadu and N100.
- `kube-ops`: Kubernetes/Argo desired state after kubeconfig handoff.

Do not add Terraform/OpenTofu here.

## Read order

Vision and active cross-repo decisions live in `homelab-infra`: [charter](https://github.com/SmadjaPaul/homelab-infra/blob/main/docs/charter.md) and [decisions](https://github.com/SmadjaPaul/homelab-infra/blob/main/docs/decisions.md). Read them once per session; they win over older tickets and docs.

For a task read: this file → one relevant skill under `.agents/skills/` → only the application/infrastructure subtree being changed. Use `just inventory` before crawling the repository.

## Skill routing

| Task | Entry skill |
|---|---|
| unfamiliar repository | `.agents/skills/repo-navigation` |
| adding or retiring a service | `docs/operations/service-onboarding.md` |
| Argo sync/health | `.agents/skills/argocd-debug` |
| Kubernetes workload failure | `.agents/skills/kubernetes-debug` |
| runtime/post-merge proof | `.agents/skills/runtime-observer` |
| OIDC/Auth | `.agents/skills/oidc-integration` |
| backup/restore | `.agents/skills/backup-restore` |
| incident triage | `.agents/skills/sre-triage` |

`.agents/` is the single shared agent knowledge tree. Do not create parallel Codex/OpenCode prompt trees. Claude discovers them through a `skills` symlink in the Claude config directory.

## Evidence levels

Never collapse these levels:
1. STATIC — render/schema/policy checks pass.
2. RECONCILED — Argo reports the desired revision Synced and controllers accepted resources.
3. RUNTIME — workloads, dependencies, Service/EndpointSlice, Gateway, DNS and TLS work.
4. USER — a real user can authenticate and complete the intended durable action.

A merged PR proves none of levels 2-4 by itself.

## Operator Kubernetes access

Runtime commands MUST NOT ask the user to provide a `KUBECONFIG` and MUST NOT
fall back to `~/.kube/config`. The canonical operator kubeconfig is distributed
by `homelab-infra` into Doppler `infrastructure/prd` as
`KUBERNETES_OPERATOR_KUBECONFIG` plus
`KUBERNETES_OPERATOR_KUBECONFIG_SHA256`.

`scripts/lib/kube-preflight.sh` auto-materializes that canonical copy into a
mode-0600 temporary file, verifies its fingerprint, verifies TLS/client auth
against the live API, exports it only for the current process, and removes it on
exit. Ambient/ad-hoc kubeconfigs are ignored by default so a stale local context
cannot silently win.

If runtime access fails:
1. run `just kube-access-check`;
2. if Doppler is unauthenticated, authenticate Doppler and retry;
3. if the canonical copy is missing, mismatched, or cannot authenticate, recover
   it from `homelab-infra` with `just kube-access-sync` there;
4. never ask Paul to paste/export a kubeconfig, never write `~/.kube/config`,
   and never use `--insecure-skip-tls-verify`.

## Operator command surface

Prefer repository commands over improvised shell:
- `just inventory` (Git-only active imports and dormant candidates; not runtime evidence)
- `just kube-access-check`
- `just check`
- `just runtime-inventory`
- `just runtime-smoke`
- `just status-app <argo-app>`
- `just diagnose-app <argo-app>`
- `just backup-audit`
- `just e2e-list`
- `bash scripts/kubectl-ro.sh <get|describe|logs|top|events|api-resources|version> ...` (ad hoc read-only kubectl through `scripts/lib/kube-preflight.sh`; the default access path until the limited-rights write identity and write wrapper of PLT-237 are deployed; never call `kubectl` without the preflight)
- `bash scripts/doppler-safe.sh <names|has|set|delete|run>` (Doppler entry point for agents; masks values of 8+ characters only, not base64/URL-encoded forms)

## Reference (on demand)

Current platform, runtime evidence order and PR test-result reporting: `.agents/skills/runtime-observer/SKILL.md`. Every PR body lists checks run (with result) and checks not run (with reason); a missing check is never a pass.

## Safety

Full-auto build phase (decision D-2026-11-13-01 and D-2026-11-11-02 in [decisions](https://github.com/SmadjaPaul/homelab-infra/blob/main/docs/decisions.md); Linear PLT-235): the agent decides and executes without per-action approval. Safety is per operation and per resource, not a general ban on mutation. Agents work on their own claude/ or codex/ branch prefix, never on another agent's branch.

Allowed without per-action approval, inside the admitted scope (reconstructible, non-critical namespaces and applications):
- `kubectl apply/patch/scale/rollout/restart`, suspending Jobs, deleting reconstructible workloads;
- merging green PRs through the normal flow;
- the already-authorized cleanups and deletions (PLT-46, PLT-94) inside their exact perimeter;
- the bounded recovery commands (D-2026-11-11-13), each of which checks its own preconditions and data protections and refuses otherwise: `bash scripts/argo-terminate-stuck-sync.sh APP [MIN_AGE] [--dry-run]` terminates a sync stuck on hooks/health once no unprotected PVC/PV/CNPG Cluster/ObjectStore/non-empty namespace would be pruned;
- OpenTofu plan and apply through ARC CI on the admitted roots, triggered by the agent (homelab-infra side).

Every mutation follows three obligations:
1. Scope: only admitted namespaces/applications and a limited-rights identity.
2. Runtime verification: observe the result (Argo, workload, Service/EndpointSlice, Gateway, DNS/TLS) and report the evidence level.
3. GitOps reconciliation: any durable change is committed to Git (branch -> checks -> PR -> merge -> Argo) the same day, so cluster and Git never diverge.

Write access path: the limited-rights write identity and the write wrapper are delivered by PLT-237 (agent RBAC). Until they are deployed, read-only access through `scripts/kubectl-ro.sh` stays the default and mutations go through Git and the bounded recovery commands. This repository does not invent another write tool.

The Argo MCP stays read-only observation (`role:readonly`); operations never go through the MCP account.

Reinforced protections, per operation and per resource (explicit approval from Paul required):
- irreplaceable data: never delete the only copy of a datum, copy it to R2 first; no PVC deletion/reinitialization or backup deletion outside the cases already authorized (PLT-46, PLT-94, abandoned applications listed in the project instructions);
- identity resources (Authentik, Matrix) and root secrets, including identity-root rotation;
- structural network changes (Cilium, Gateway, DNS, cluster access) and new public exposure or privilege escalation;
- irreversible migrations;
- disabling desired apps merely to make Argo green.

Local executors (Mac) use the native macOS shell, never `device_bash` nor the Linux VM. The `night-relay` supervisor is retired (PLT-236) and must not be relaunched; the coordinator cascade drives the work.

Always forbidden: `--admin` or any bypass of a protection or required check, TLS disabled or `-k`, displaying or committing a secret, reading Secret values, `device_bash` and the Mac Linux VM, OpenTofu apply outside CI.

Secret output (enforced by `.claude/hooks/secret-output-guard.py`, applies in every mode):
- run Doppler through `scripts/doppler-safe.sh`; never run `doppler secrets` without `--only-names`, nor `doppler secrets get|download|set|delete` directly: they print values, even with `--silent`, on stdout and stderr;
- never run `doppler run -- env|printenv`, bare `printenv`, `env`, `set` or `export -p`; list names only (`env | cut -d= -f1`);
- never run `kubectl get secret` with `-o`/`--output` (except `-o name`), nor any `kubectl -v=6` or higher; use `kubectl describe secret` for key names and sizes;
- redirecting stdout alone does not count as protection: stderr, error tables and transcripts keep the values.

Bounded `kubectl get/describe/logs` is evidence. A durable change is complete only after the Git reconciliation and the runtime proof above.

## Validation

Run `just check` for desired-state changes. Stateful workloads are incomplete until backup coverage exists; data that matters is incomplete until restore has been proven at least once.

## Context discipline

Do not load the whole repository. If a normal task cannot be solved from this router + one skill + one app tree + bounded runtime evidence, improve navigation/scripts instead of creating mega-context documents.
