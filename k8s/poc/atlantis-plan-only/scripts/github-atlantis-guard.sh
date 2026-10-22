#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Atlantis admission denied: $*" >&2
  if test -n "${OUTPUT_STATUS_FILE:-}"; then
    echo failure >"$OUTPUT_STATUS_FILE"
  fi
  exit 1
}

test "${BASE_REPO_OWNER:-}/${BASE_REPO_NAME:-}" = "SmadjaPaul/homelab-infra" ||
  fail "unexpected base repository"
test "${HEAD_REPO_OWNER:-}/${HEAD_REPO_NAME:-}" = "$BASE_REPO_OWNER/$BASE_REPO_NAME" ||
  fail "forks are not admitted"
test "${BASE_BRANCH_NAME:-}" = main || fail "only the main base branch is admitted"
test "${PROJECT_NAME:-}" != "" || fail "unnamed projects are not admitted"
test "${HEAD_COMMIT:-}" != "" || fail "an immutable head commit is required"
test -z "${COMMENT_ARGS:-}" || fail "comment arguments are not admitted"

# No GitHub App or PAT fallback can be inherited by the provider. The App
# variables are installed by the server-owned workflow env steps, not by the
# repository checkout.
for fallback in GITHUB_TOKEN GH_TOKEN TF_VAR_github_token GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PEM_FILE; do
  test -z "${!fallback:-}" || fail "credential fallback $fallback is set"
done

case "$PROJECT_NAME" in
  atlantis-pilot)
    test "$REPO_REL_DIR" = terraform/atlantis-pilot || fail "pilot root mismatch"
    test -f "$DIR/terraform/atlantis-pilot/backend.tf" || fail "pilot backend is missing"
    test -f "$DIR/terraform/atlantis-pilot/main.tf" || fail "pilot root is missing"
    grep -Eq 'required_version = "= 1\.13\.1"' "$DIR/terraform/atlantis-pilot/versions.tf" ||
      fail "pilot toolchain is not pinned"
    grep -Eq 'key[[:space:]]*=[[:space:]]*"atlantis-pilot/terraform.tfstate"' "$DIR/terraform/atlantis-pilot/backend.tf" ||
      fail "pilot state key is not canonical"
    grep -Eq 'bucket[[:space:]]*=[[:space:]]*"homelab-atlantis-pilot-tfstate"' "$DIR/terraform/atlantis-pilot/backend.tf" ||
      fail "pilot bucket is not isolated"
    grep -Eq 'use_lockfile[[:space:]]*=[[:space:]]*true' "$DIR/terraform/atlantis-pilot/backend.tf" ||
      fail "pilot lockfile is not enabled"
    if grep -REn '^[[:space:]]*(provider|module|data|provisioner)[[:space:]]' "$DIR/terraform/atlantis-pilot"/*.tf; then
      fail "pilot contains an external execution surface"
    fi
    base_ref="origin/$BASE_BRANCH_NAME"
    git rev-parse "$base_ref^{commit}" >/dev/null 2>&1 ||
      fail "base branch ref is unavailable"
    git rev-parse "$HEAD_COMMIT^{commit}" >/dev/null 2>&1 ||
      fail "head commit is unavailable"
    changed=$(git diff --name-only "$base_ref...$HEAD_COMMIT")
    while IFS= read -r path; do
      test -z "$path" && continue
      case "$path" in
        terraform/atlantis-pilot/*) ;;
        *) fail "pilot file is outside the fixture allowlist: $path" ;;
      esac
    done <<<"$changed"
    ;;
  github)
    test "$REPO_REL_DIR" = terraform/github || fail "GitHub root mismatch"
    test -f "$DIR/terraform/github/backend.tf" || fail "GitHub backend is missing"
    test -f "$DIR/terraform/github/provider.tf" || fail "GitHub provider is missing"
    grep -Eq 'bucket[[:space:]]*=[[:space:]]*"homelab-github-tfstate"' "$DIR/terraform/github/backend.tf" ||
      fail "GitHub bucket is not isolated"
    grep -Eq 'key[[:space:]]*=[[:space:]]*"github/terraform.tfstate"' "$DIR/terraform/github/backend.tf" ||
      fail "GitHub state key is not canonical"
    grep -Eq 'use_lockfile[[:space:]]*=[[:space:]]*true' "$DIR/terraform/github/backend.tf" ||
      fail "GitHub native lockfile is not enabled"
    if grep -Eq 'REPLACE_WITH_DEDICATED_GITHUB_STATE_' "$DIR/terraform/github/backend.tf"; then
      fail "GitHub backend still contains a placeholder"
    fi
    grep -Eq 'version[[:space:]]*=[[:space:]]*"= 6\.13\.0"' "$DIR/terraform/github/versions.tf" ||
      fail "GitHub provider pin changed without admission"
    grep -Eq 'app_auth[[:space:]]*\{' "$DIR/terraform/github/provider.tf" ||
      fail "GitHub provider App authentication is not explicit"

    # The only mutable input admitted to the privileged provider is the
    # repository settings data file. Provider code, backends, modules, data
    # sources, provisioners and workflows are trusted from the base branch.
    base_ref="origin/$BASE_BRANCH_NAME"
    git rev-parse "$base_ref^{commit}" >/dev/null 2>&1 ||
      fail "base branch ref is unavailable"
    git rev-parse "$HEAD_COMMIT^{commit}" >/dev/null 2>&1 ||
      fail "head commit is unavailable"
    changed=$(git diff --name-only "$base_ref...$HEAD_COMMIT")
    while IFS= read -r path; do
      test -z "$path" && continue
      test "$path" = terraform/github/repositories.auto.tfvars ||
        fail "file is outside the GitHub data-only allowlist: $path"
    done <<<"$changed"
    test -f "$DIR/terraform/github/repositories.auto.tfvars" ||
      fail "GitHub settings input is missing"
    test -n "${AWS_ACCESS_KEY_ID:-}" || fail "GitHub state identity is missing"
    test -n "${AWS_SECRET_ACCESS_KEY:-}" || fail "GitHub state identity is missing"
    test -n "${TF_VAR_github_app_id:-}" || fail "GitHub App identity is missing"
    test -n "${TF_VAR_github_app_installation_id:-}" || fail "GitHub App installation is missing"
    test -n "${TF_VAR_github_app_pem_file:-}" || fail "GitHub App key is missing"
    ;;
  *)
    fail "unknown project $PROJECT_NAME"
    ;;
esac

echo "Atlantis admission accepted: project=$PROJECT_NAME base=$BASE_REPO_OWNER/$BASE_REPO_NAME head=$HEAD_COMMIT"
