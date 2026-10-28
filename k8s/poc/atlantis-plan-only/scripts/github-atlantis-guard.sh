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

# Only the disposable pilot, immutable GitHub admission files, documentation,
# static tests, and the exact generated OpenTofu module README files currently
# qualified by the homelab-infra documentation contract may differ in a PR that
# reaches this server. In particular, no provider, resource, data source,
# provisioner, workflow, or arbitrary Terraform file can be introduced
# alongside an admin plan. Keep this list literal: a broad Bash glob would
# silently admit nested or newly introduced module paths. The exact
# google-cloud-build bootstrap files are admitted individually so the
# server-side envelope and wrapper can bind their contents later; this does
# not admit the root to Atlantis or enable apply.
changed=$(git diff --name-only "$base_ref...$HEAD_COMMIT")
while IFS= read -r path; do
  test -z "$path" && continue
  case "$path" in
    terraform/atlantis-pilot/*|terraform/github/repositories.auto.tfvars|terraform/github/backend.tf|terraform/github/*.md|\
    terraform/aiostreams/backend.tf|terraform/aiostreams/main.tf|terraform/aiostreams/variables.tf|\
    terraform/aiostreams/versions.tf|terraform/aiostreams/.terraform.lock.hcl|\
    terraform/aiostreams/README.md|terraform/aiostreams/terraform.tfvars.example|\
    terraform/doppler/aiostreams-atlantis-backend.tf|\
    terraform/oracle-cloud/aiostreams-state-backend.tf|\
    terraform/oracle-cloud/aiostreams-state-backend-variables.tf|\
    terraform/cloudflare/modules/access/README.md|\
    terraform/cloudflare/modules/comet-cache-rules/README.md|\
    terraform/cloudflare/modules/dns/README.md|\
    terraform/cloudflare/modules/email_routing/README.md|\
    terraform/cloudflare/modules/global_config/README.md|\
    terraform/cloudflare/modules/legacy-dns/README.md|\
    terraform/cloudflare/modules/rate-limit/README.md|\
    terraform/cloudflare/modules/security-headers/README.md|\
    terraform/cloudflare/modules/security/README.md|\
    terraform/cloudflare/modules/tunnel/README.md|\
    terraform/cloudflare/modules/waf-managed-rules/README.md|\
    terraform/migadu/modules/aliases/README.md|\
    terraform/migadu/modules/identities/README.md|\
    terraform/migadu/modules/mailboxes/README.md|\
    terraform/netbird/modules/global_config/README.md|\
    terraform/oracle-cloud/modules/admin/README.md|\
    terraform/oracle-cloud/modules/monitoring/README.md|\
    terraform/oracle-cloud/modules/network/README.md|\
    terraform/oracle-cloud/modules/object-storage/README.md|\
    terraform/proxmox/modules/talos/README.md|\
    .atlantis/plan-only.yaml|.atlantis/policies/google-cloud-build-bootstrap/main.rego|\
    terraform/google-cloud-build/README.md|\
    terraform/google-cloud-build/evidence-bucket.tf|\
    terraform/google-cloud-build/github-identity.tf|\
    terraform/google-cloud-build/imports.tf|\
    terraform/google-cloud-build/main.tf|\
    terraform/google-cloud-build/variables.tf|\
    .github/workflows/static-ci.yml|.gitignore|.justfile|docs/*|mise.lock|mise.toml|\
    tests/fixtures/google-cloud-build-bootstrap/valid.template.json|\
    tests/google-cloud-build-bootstrap-policy.sh|\
    tests/*|scripts/architecture-check.sh|scripts/live-tofu.sh) ;;
    *) fail "file is outside the server admission allowlist: $path" ;;
  esac
done <<<"$changed"

test -f "$DIR/terraform/github/backend.tf" || fail "GitHub backend is missing"
test "$(git hash-object "$DIR/terraform/github/backend.tf")" = "63d68a69487cf768e662ed0b1c4d8ae93f3bcd19" ||
  fail "GitHub backend is not the server-admitted canonical file"
test -f "$DIR/.atlantis/plan-only.yaml" || fail "server project registry is missing"
case "$(git hash-object "$DIR/.atlantis/plan-only.yaml")" in
  fc66d3b6d8c59581cf3f771b33766d1ebcb042a3|79522bce630cad360a6ebe3bf6f1ebc965379cb9|37cf4ab1d01f0228a305d54f458e7a9c51930127) ;;
  *) fail "server project registry changed outside admission" ;;
esac
test -f "$DIR/terraform/github/provider.tf" || fail "GitHub provider is missing"
grep -Eq 'version[[:space:]]*=[[:space:]]*"= 6\.13\.0"' "$DIR/terraform/github/versions.tf" ||
  fail "GitHub provider pin changed without admission"
grep -Eq 'app_auth[[:space:]]*\{' "$DIR/terraform/github/provider.tf" ||
  fail "GitHub provider App authentication is not explicit"
test -f "$DIR/terraform/github/repositories.auto.tfvars" ||
  fail "GitHub settings input is missing"

# Security-sensitive files from the one-time Factory admission are not
# admitted by pathname alone. The server-owned policy pins the exact PR head
# and content digests reviewed for this admission. Any amended PR, even at the
# same paths, requires a new server-owned admission update.
admitted_factory_head="54774b1924663761b608624bb993bd025d02e38d"
admit_factory_security_file() {
  local path=$1 expected_hash=$2
  test "$HEAD_COMMIT" = "$admitted_factory_head" ||
    fail "Factory security path requires the server-admitted head: $path"
  test "$(git hash-object "$DIR/$path")" = "$expected_hash" ||
    fail "Factory security path content is not server-admitted: $path"
}

path_changed() {
  local expected=$1 path
  while IFS= read -r path; do
    test "$path" = "$expected" && return 0
  done <<<"$changed"
  return 1
}

if path_changed .atlantis/policies/google-cloud-build-bootstrap/main.rego; then
  admit_factory_security_file \
    .atlantis/policies/google-cloud-build-bootstrap/main.rego \
    29e96dc002d1430ab77d0d8e5fe21c04439cd8e1
fi
if path_changed scripts/live-tofu.sh; then
  admit_factory_security_file \
    scripts/live-tofu.sh \
    74914cb0407e4669dc8511a8e8ccc4c61aa99f57
fi

echo "Atlantis admission accepted: server-owned diff boundary base=$BASE_REPO_OWNER/$BASE_REPO_NAME head=$HEAD_COMMIT"
