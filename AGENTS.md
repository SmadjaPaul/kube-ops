# AGENTS.md — kube-ops operating router

Git is the Kubernetes desired-state authority. Argo CD continuously reconciles Git. Runtime tools provide evidence; they are never a second steady-state mutation plane.

## Authority

When sources disagree use: accepted repository contracts > this router > desired-state code > runtime as observed evidence. Runtime drift never silently becomes desired state.

Repository boundary:
- `homelab-infra`: Proxmox/Talos substrate, UniFi/LAN DNS, Cloudflare account/edge, Doppler bootstrap, Hetzner, Migadu and N100.
- `kube-ops`: Kubernetes/Argo desired state after kubeconfig handoff.

Do not add Terraform/OpenTofu here.

## Read order

For a task read: this file → one relevant skill under `.agents/skills/` → only the application/infrastructure subtree being changed. Use `just inventory` before crawling the repository.

## Current platform

- Talos 1.13.10 / Kubernetes 1.36.3, one schedulable node for V1.
- Cilium + Gateway API; `Gateway/internal` LAN VIP is `10.0.20.192`.
- private ExternalDNS derives application names from internal HTTPRoutes and publishes them into UniFi DNS.
- UniFi DNS is the private application authority; AdGuard is filtering/cache only.
- Argo CD is the only steady-state Kubernetes reconciler.
- Longhorn `longhorn-fast` / `longhorn-bulk`.
- CNPG/Barman and Velero/Kopia -> Hetzner Object Storage.
- Doppler -> ESO for runtime secrets; never inspect Secret values.
- Authentik is the identity authority.
- public access is Cloudflare Tunnel -> Gateway/external.

## Skill routing

| Task | Entry skill |
|---|---|
| unfamiliar repository | `.agents/skills/repo-navigation` |
| Argo sync/health | `.agents/skills/argocd-debug` |
| Kubernetes workload failure | `.agents/skills/kubernetes-debug` |
| runtime/post-merge proof | `.agents/skills/runtime-observer` |
| OIDC/Auth | `.agents/skills/oidc-integration` |
| backup/restore | `.agents/skills/backup-restore` |
| incident triage | `.agents/skills/sre-triage` |

`.agents/` is the single shared agent knowledge tree. Do not create parallel Codex/OpenCode prompt trees.

## Evidence levels

Never collapse these levels:
1. STATIC — render/schema/policy checks pass.
2. RECONCILED — Argo reports the desired revision Synced and controllers accepted resources.
3. RUNTIME — workloads, dependencies, Service/EndpointSlice, Gateway, DNS and TLS work.
4. USER — a real user can authenticate and complete the intended durable action.

A merged PR proves none of levels 2-4 by itself.

## Coding-agent test results

Every coding-agent handoff must carry a machine-readable test result, even when
some checks were not run. Use the versioned contract in
`docs/contracts/agent-test-result-v1.schema.json` and include one record per
planned check. Each record must distinguish `executed` from `not-executed`, use
the classification `passed`, `failed`, `skipped`, `unavailable`, or
`not-applicable`, and state its reason, risk, and expected CI treatment.

Hooks may generate or transport this record, but they are advisory only. The
agent instructions and handoff remain responsible for producing the result and
for calling out missing, unavailable, or out-of-scope checks. Never turn a
missing hook artifact into an implied pass. The `transmission` projection is
the transport shape for the separate `factory-platform` evidence consumer; it
does not authorize telemetry/runtime changes in this repository.

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
- `just inventory`
- `just kube-access-check`
- `just check`
- `just runtime-inventory`
- `just runtime-smoke`
- `just status-app <argo-app>`
- `just diagnose-app <argo-app>`
- `just backup-audit`
- `just e2e-list`

## Runtime evidence order

```
Git desired state
  -> Argo Application/ApplicationSet
  -> controller resource status
  -> Kubernetes workload / Service / EndpointSlice
  -> Gateway / DNS / TLS
  -> user journey
```

For HTTP failures distinguish DNS, TLS, HTTPRoute status, ready EndpointSlices and the application response. Do not debug OAuth while DNS/TLS/backend routing is unproven.

## Safety

Without explicit operator approval:
- no apply/delete/patch/edit/scale/restart as durable repair;
- no infrastructure apply/destroy/state mutation;
- no Secret value reads or credential printing;
- no TLS bypass with `-k`;
- no PVC deletion/reinitialization;
- no new public exposure, privilege escalation, identity-root rotation or irreversible migration;
- no disabling desired apps merely to make Argo green.

Bounded read-only `kubectl get/describe/logs` is evidence. Durable repair is branch -> checks -> PR -> merge -> Argo -> runtime proof.

## Validation

Run `just check` for desired-state changes. Stateful workloads are incomplete until backup coverage exists; data that matters is incomplete until restore has been proven at least once.

## Context discipline

Do not load the whole repository. If a normal task cannot be solved from this router + one skill + one app tree + bounded runtime evidence, improve navigation/scripts instead of creating mega-context documents.
