#!/usr/bin/env bash
set -euo pipefail

deny() {
  printf 'Atlantis Infra admission denied: %s\n' "$*" >&2
  exit 1
}

[[ "${BASE_REPO_OWNER:-}/${BASE_REPO_NAME:-}" == "SmadjaPaul/homelab-infra" ]] || deny 'base repository'
[[ "${HEAD_REPO_OWNER:-}/${HEAD_REPO_NAME:-}" == "$BASE_REPO_OWNER/$BASE_REPO_NAME" ]] || deny 'fork'
[[ "${BASE_BRANCH_NAME:-}" == main ]] || deny 'base branch'
[[ -z "${COMMENT_ARGS:-}" ]] || deny 'comment arguments'
[[ "${WORKSPACE:-}" == default ]] || deny 'workspace'
[[ "${REPO_REL_DIR:-}" == terraform/github || "${REPO_REL_DIR:-}" == terraform/unifi ]] || deny 'root is not admitted to this executor'
[[ "${PROJECT_NAME:-}" == "${REPO_REL_DIR#terraform/}" ]] || deny 'project/root mismatch'
[[ -n "${HEAD_COMMIT:-}" ]] || deny 'immutable head missing'
[[ -f "${DIR:-}/backend.tf" ]] || deny 'backend missing'
[[ -f "${DIR:-}/.terraform.lock.hcl" ]] || deny 'provider lockfile missing'

# This is a narrow pre-plan provenance boundary, not a sandbox. Atlantis
# executes provider code during init/plan, so toolchain, backend, module and
# executor changes are never allowed through the privileged Infra workflow.
git rev-parse 'origin/main^{commit}' >/dev/null 2>&1 || deny 'base unavailable'
git rev-parse "${HEAD_COMMIT}^{commit}" >/dev/null 2>&1 || deny 'head unavailable'
changed_root=false
while IFS= read -r -d '' path; do
  case "$path" in
    "terraform/$PROJECT_NAME/backend.tf"|"terraform/$PROJECT_NAME/provider.tf"|"terraform/$PROJECT_NAME/versions.tf"|"terraform/$PROJECT_NAME/.terraform.lock.hcl"|terraform/modules/*|.atlantis*|docs/architecture/atlantis-runtime-*.yaml)
      deny "unadmitted execution or toolchain change: $path" ;;
    "terraform/$PROJECT_NAME/"*) changed_root=true ;;
    docs/*|tests/*) ;;
    *) deny "unexpected path: $path" ;;
  esac
done < <(git diff --name-only -z "origin/main...$HEAD_COMMIT" --)
[[ "$changed_root" == true ]] || deny 'no change in selected root'

case "$PROJECT_NAME" in
  github)
    [[ -f /etc/atlantis/roots/github/backend/AWS_ACCESS_KEY_ID ]] || deny 'GitHub backend identity unavailable'
    [[ -f /etc/atlantis/roots/github/provider/TF_VAR_github_app_pem_file ]] || deny 'GitHub provider identity unavailable'
    ;;
  unifi)
    [[ -f /etc/atlantis/roots/unifi/backend/AWS_ACCESS_KEY_ID ]] || deny 'UniFi backend identity unavailable'
    [[ -f /etc/atlantis/roots/unifi/provider/TF_VAR_unifi_integration_api_key ]] || deny 'UniFi provider identity unavailable'
    ;;
  *) deny 'unknown project';;
esac

printf 'Atlantis Infra root admission PASS: %s\n' "$PROJECT_NAME"
