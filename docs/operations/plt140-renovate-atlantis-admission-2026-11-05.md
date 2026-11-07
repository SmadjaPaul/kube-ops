# PLT-140 — narrow Atlantis admission of Renovate tooling policy

**Scope**: the server-owned pre-workflow hook at
`k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh` previously denied
`homelab-infra#243` because `renovate.json` was absent from its literal
admission list. The refusal is correct for arbitrary files.

This change admits exactly **one audited Git blob ID**:
`3704e49612b76dde0a78c4a1f84d2d505fdf3eab` for
`SmadjaPaul/homelab-infra/renovate.json` in PR
[#243](https://github.com/SmadjaPaul/homelab-infra/pull/243).
Every other content revision fails the server hook. Normal same-repository,
`main`, no-fork, GitHub provider/At​​lantis plan and server security checks remain
unchanged. This explicitly does **not** admit arbitrary Terraform roots or
provider/CI policy changes, and does not grant the repository an Atlantis apply.

The audited config keeps global `automerge=false`,
`platformAutomerge=false`, `ignoreTests=false`,
`internalChecksFilter=strict` and rebase-on-behind; only known
`mise-en-place` tools from the root `mise.toml` are automerged on stable
patch/minor or pre-1.0 patch updates, with minimum age 14 days and CI green.
`mise.toml` pins `gh`, `yq` and `jq` to already-locked versions and
introduces no tool binary upgrade.

This guard change must be promoted by protected GitOps, and then validated
against the actual PR #243 re-triggering its Atlantis pre-workflow hook.
The config hash is deliberately **not** a general-purpose permanent
renovate.json exemption; extending the auto list requires explicit server
admission, or a separately reviewed, test-covered capability-limited guard.
Do not bypass red Atlantis statuses or manually mark them successful.

**No cluster mutation was attempted in authoring this plan.**
