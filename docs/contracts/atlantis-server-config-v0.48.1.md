# Atlantis OSS v0.48.1 server contract

**Status:** isolated `terraform/atlantis-pilot` qualified on 2026-10-22;
the twelve production roots remain pending individual qualification.

## Upstream audit

| Control | Candidate configuration | Result |
| --- | --- | --- |
| Repository allowlist | `github.com/SmadjaPaul/homelab-infra`; explicit `/.*/` deny rule; forks and drafts disabled | PASS |
| Server-side authority | exact repo mapping, `allowed_overrides: []`, `allow_custom_workflows: false` | PASS |
| Plan admission | `mergeable`, `undiverged`; exact repo/head/root/project/backend/toolchain checks in the native workflow | PASS |
| Apply admission | only the exact pilot mapping; `disableApplyAll: true`; `mergeable`, `undiverged`; no GitHub `approved` requirement | PASS (runtime) |
| Policy check | server `--enable-policy-checks`, local Conftest policy mounted from GitOps ConfigMap, no policy owner able to approve a failure | PASS (runtime: 12/12) |
| Apply scope | native `apply` step consumes Atlantis' saved plan; policy admits only `terraform_data.pilot` create/no-op | PASS (runtime) |
| Post-apply verification | server-side apply hook verifies repository, base branch, project, OpenTofu binary, workspace and exact state address | PASS (runtime) |
| Locking | Atlantis `repo_locks.mode: on_plan`; OCI backend `use_lockfile = true` | PASS (runtime) |
| Custom workflows / arguments | PR workflow is not trusted; custom workflows and overrides are disabled; empty comment arguments are required | PASS |
| Credentials and egress | dedicated ESO secret and OCI egress only; no operator credential; provider registry remains denied | PASS (runtime) |

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

## Post-workflow hook environment

The server-owned `post_workflow_hooks` run outside the custom workflow steps.
Their supported built-ins include `DIR` (the absolute checkout root),
`PROJECT_NAME`, `HEAD_COMMIT`, `COMMAND_NAME`, `COMMAND_HAS_ERRORS` and
`OUTPUT_STATUS_FILE`. `REPO_REL_DIR` is a custom-workflow variable and must
not be referenced by a post-workflow hook. The pilot hook therefore selects
one of its fixed, server-owned project paths below `DIR` from `PROJECT_NAME`.

## Apply and merge semantics

Atlantis OSS v0.48.1 applies the saved plan through the native `apply` command;
it does not autonomously invoke apply merely because plan succeeded. The
qualified autonomous path therefore means that an admitted agent invokes
Atlantis' apply command without a human approval gate, and Atlantis applies the
saved plan, runs the server-side verification hook, then may automerge only
after all configured plans and applies succeed. An uncertain or failed hook
must prevent merge.

The server-side `Repo` schema in v0.48.1 has no `automerge` field; adding one
crashes Atlantis during repository-config parsing. Automerge is controlled by
the server flag and the repository's own Atlantis config, with an explicit
repository declaration taking precedence. The pilot contract must therefore
not invent a server-side `automerge` key; a qualification that must remain
open needs a supported command-level `--auto-merge-disabled` control or a
separately admitted repository-config change.

References: [server-side repository configuration](https://www.runatlantis.io/docs/server-side-repo-config),
[command requirements](https://www.runatlantis.io/docs/command-requirements),
[policy checking](https://www.runatlantis.io/docs/policy-checking),
[post workflow hooks](https://www.runatlantis.io/docs/post-workflow-hooks),
[automerging](https://www.runatlantis.io/docs/automerging),
[locking](https://www.runatlantis.io/docs/locking),
[security](https://www.runatlantis.io/docs/security).
