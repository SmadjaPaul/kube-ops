# Atlantis OSS v0.48.1 server contract

**Status:** dormant source contract; not an activation approval (2026-10-16)

The pinned chart/image in `k8s/poc/atlantis-plan-only` is a qualification
fixture. It is not connected to an Argo ApplicationSet and keeps apply,
import and state mutation disabled. The server configuration below records the
properties that a future multi-stack activation must preserve.

## Server-side precedence

Atlantis reads the server-side repository configuration through
`--repo-config` / `ATLANTIS_REPO_CONFIG`. Server flags take precedence over
environment variables, which take precedence over the server config file. The
repository configuration is therefore server-owned; a pull request cannot
change this precedence or the server flags.

The first repository entry is an explicit `/.*/` deny rule and the exact
`github.com/SmadjaPaul/homelab-infra` entry follows it. Atlantis applies the
last matching repository entry. This order is tested from source and rendered
manifests. `allowed_overrides: []` and `allow_custom_workflows: false` are set
on both entries. The repository's `repo_config_file` may describe projects,
but it cannot select a custom workflow or override server-side requirements.

## Qualification controls

- repository allowlist is exactly `github.com/SmadjaPaul/homelab-infra`;
- fork and draft pull requests are disabled;
- `version`, `plan` and `policy_check` are the only enabled commands in the
  dormant fixture;
- the workflow checks the base/head repository, exact project and directory,
  empty comment arguments, current PR admission state, exact tool version and
  placeholder backend before `init` or `plan`;
- the fixture uses `use_lockfile = true`, has no provider/module/data source or
  provisioner, and cannot reach OCI or a provider registry;
- apply, import and state operations fail closed in both server flags and the
  server workflow.

The plan workflow's `HEAD_COMMIT` is the immutable pull-request head supplied
by Atlantis. A future activation must bind any apply to that exact SHA, root,
workspace, state lineage, toolchain and policy revision and must invalidate it
when any of those values changes. A normal PR approval is code admission, not
plan approval.

## Multi-stack activation boundary

The final registry lives in `homelab-infra` and records all roots. This
repository owns only the Atlantis server deployment and must not duplicate
OpenTofu state or add Kubernetes/Helm providers. An activation PR must add the
server-side project/workflow mappings from the registry, exact provider and
OCI destinations, stack-scoped identities, budget/change policy, independent
post-apply observation and off-cluster recovery evidence.

Atlantis OSS v0.48.1 does not natively start an apply automatically after a
successful plan: its native apply path is a comment or authenticated API
request, and `automerge` merges after plans have already been applied. Therefore
"autonomous apply without a named human approval" requires a separately
reviewed authorized API caller or another supported control-plane integration.
No such caller, token or custom replacement script is created here. Enabling
`apply_requirements: [mergeable, undiverged]` alone would not create an
automatic apply and must not be represented as runtime evidence.

References: [server configuration](https://www.runatlantis.io/docs/server-configuration),
[server-side repo config](https://www.runatlantis.io/docs/server-side-repo-config),
[custom workflows](https://www.runatlantis.io/docs/custom-workflows),
[command requirements](https://www.runatlantis.io/docs/command-requirements),
[security](https://www.runatlantis.io/docs/security).
