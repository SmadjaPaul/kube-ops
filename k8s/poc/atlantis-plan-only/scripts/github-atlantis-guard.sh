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
test "${HEAD_COMMIT:-}" != "" || fail "an immutable head commit is required"
test -z "${COMMENT_ARGS:-}" || fail "comment arguments are not admitted"

# No GitHub App or PAT fallback can be inherited by the provider. The App
# variables are installed by the server-owned workflow env steps, not by the
# repository checkout.
for fallback in GITHUB_TOKEN GH_TOKEN TF_VAR_github_token GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PEM_FILE; do
  test -z "${!fallback:-}" || fail "credential fallback $fallback is set"
done

# Pre-workflow hooks run before Atlantis parses the repository project list, so
# PROJECT_NAME is intentionally not used here: it is empty for autoplan. Keep
# this hook as a global server-owned trust boundary and let the later workflow
# validate PROJECT_NAME/REPO_REL_DIR for the selected project.
base_ref="origin/$BASE_BRANCH_NAME"
git rev-parse "$base_ref^{commit}" >/dev/null 2>&1 ||
  fail "base branch ref is unavailable"
git rev-parse "$HEAD_COMMIT^{commit}" >/dev/null 2>&1 ||
  fail "head commit is unavailable"

# Only the disposable pilot, the immutable GitHub admission files, and
# documentation/static tests may differ in a PR that reaches this server. In
# particular, no provider, module, data source, provisioner, workflow, or
# arbitrary Terraform file can be introduced alongside an admin plan.
changed=$(git diff --name-only "$base_ref...$HEAD_COMMIT")
while IFS= read -r path; do
  test -z "$path" && continue
  case "$path" in
    terraform/atlantis-pilot/*|terraform/github/repositories.auto.tfvars|terraform/github/backend.tf|terraform/github/*.md|.atlantis/plan-only.yaml|.gitignore|docs/*|tests/*|scripts/architecture-check.sh) ;;
    *) fail "file is outside the server admission allowlist: $path" ;;
  esac
done <<<"$changed"

test -f "$DIR/terraform/github/backend.tf" || fail "GitHub backend is missing"
test "$(git hash-object "$DIR/terraform/github/backend.tf")" = "63d68a69487cf768e662ed0b1c4d8ae93f3bcd19" ||
  fail "GitHub backend is not the server-admitted canonical file"
test -f "$DIR/.atlantis/plan-only.yaml" || fail "server project registry is missing"
test "$(git hash-object "$DIR/.atlantis/plan-only.yaml")" = "fc66d3b6d8c59581cf3f771b33766d1ebcb042a3" ||
  fail "server project registry changed outside admission"
test -f "$DIR/terraform/github/provider.tf" || fail "GitHub provider is missing"
grep -Eq 'version[[:space:]]*=[[:space:]]*"= 6\.13\.0"' "$DIR/terraform/github/versions.tf" ||
  fail "GitHub provider pin changed without admission"
grep -Eq 'app_auth[[:space:]]*\{' "$DIR/terraform/github/provider.tf" ||
  fail "GitHub provider App authentication is not explicit"
test -f "$DIR/terraform/github/repositories.auto.tfvars" ||
  fail "GitHub settings input is missing"

echo "Atlantis admission accepted: server-owned diff boundary base=$BASE_REPO_OWNER/$BASE_REPO_NAME head=$HEAD_COMMIT"
