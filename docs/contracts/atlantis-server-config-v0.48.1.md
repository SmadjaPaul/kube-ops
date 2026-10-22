# Atlantis OSS v0.48.1 server contract

**Status:** isolated `terraform/atlantis-pilot` activation candidate; runtime
evidence is recorded only after Argo reconciliation and an Atlantis execution.

## Upstream audit

| Control | Candidate configuration | Result |
| --- | --- | --- |
| Repository allowlist | `github.com/SmadjaPaul/homelab-infra`; explicit `/.*/` deny rule; forks and drafts disabled | PASS (static; runtime pending) |
| Server-side authority | exact repo mapping, `allowed_overrides: []`, `allow_custom_workflows: false` | PASS |
| Plan admission | `mergeable`, `undiverged`; exact repo/head/root/project/backend/toolchain checks in the native workflow | PASS |
| Apply admission | only the exact pilot mapping; `disableApplyAll: true`; `mergeable`, `undiverged`; no GitHub `approved` requirement | PASS (static; runtime pending) |
| Policy check | server `--enable-policy-checks`, local Conftest policy mounted from GitOps ConfigMap, no policy owner able to approve a failure | PASS (static; runtime pending) |
| Apply scope | native `apply` step consumes Atlantis' saved plan; policy admits only `terraform_data.pilot` create/no-op | PASS (static; runtime pending) |
| Post-apply verification | server-side apply hook verifies repository, base branch, project, OpenTofu binary, workspace and exact state address | PASS (static; runtime pending) |
| Locking | Atlantis `repo_locks.mode: on_plan`; OCI backend `use_lockfile = true` | PASS (static; runtime pending) |
| Custom workflows / arguments | PR workflow is not trusted; custom workflows and overrides are disabled; empty comment arguments are required | PASS |
| Credentials and egress | dedicated ESO secret and OCI egress only; no operator credential; provider registry remains denied | PASS (static; runtime pending) |

The 12 production roots remain outside this exact repository mapping and retain
their existing admission boundary. This candidate does not modify their
workflows, credentials, states or permissions.

## Native policy boundary

The policy is stored at
`k8s/poc/atlantis-plan-only/policies/pilot.rego`, outside the pull request
being evaluated, and mounted read-only at `/etc/atlantis/conftest`. It rejects
every changed resource except `terraform_data.pilot`, rejects every pilot
action except `create` and `no-op`, requires the qualified fixture marker, and
rejects sensitive outputs. Static workflow checks additionally reject providers,
modules, data sources, provisioners, forbidden authorities and backend
substitution before `init` or `plan`.

This is deliberately a native Atlantis policy check. It does not add a second
Terraform/OpenTofu orchestrator and does not grant the policy an operator
identity.

## Apply and merge semantics

Atlantis OSS v0.48.1 applies the saved plan through the native `apply` command;
it does not autonomously invoke apply merely because plan succeeded. The
qualified autonomous path therefore means that an admitted agent invokes
Atlantis' apply command without a human approval gate, and Atlantis applies the
saved plan, runs the server-side verification hook, then may automerge only
after all configured plans and applies succeed. An uncertain or failed hook
must prevent merge.

References: [server-side repository configuration](https://www.runatlantis.io/docs/server-side-repo-config),
[command requirements](https://www.runatlantis.io/docs/command-requirements),
[policy checking](https://www.runatlantis.io/docs/policy-checking),
[post workflow hooks](https://www.runatlantis.io/docs/post-workflow-hooks),
[automerging](https://www.runatlantis.io/docs/automerging),
[locking](https://www.runatlantis.io/docs/locking),
[security](https://www.runatlantis.io/docs/security).
