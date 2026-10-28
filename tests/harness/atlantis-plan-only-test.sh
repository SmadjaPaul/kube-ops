#!/usr/bin/env bash
set -euo pipefail

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

kustomize build --enable-helm k8s/poc/atlantis-plan-only >"$rendered"

grep -q 'ghcr.io/runatlantis/atlantis:v0.48.1@sha256:42bde40e38ec7b89f02a2968b4b1b74b990121eb8768d0a7de7caad125344298' "$rendered"
grep -q 'chart: atlantis-6.16.1' "$rendered"
grep -q 'ATLANTIS_ALLOW_COMMANDS' "$rendered"
grep -q 'value: version,plan,apply,policy_check' "$rendered"
grep -q 'name: ATLANTIS_DISABLE_APPLY' "$rendered"
grep -q 'value: "false"' "$rendered"
if grep -Eq -- '--disable-apply$' "$rendered"; then
  echo "Atlantis pilot must not carry a CLI disable-apply setting" >&2
  exit 1
fi
grep -q 'name: atlantis-webhook' "$rendered"
grep -q 'value: /events' "$rendered"
grep -q 'name: atlantis-github-app' "$rendered"
grep -q 'key.pem' "$rendered"
grep -q 'ATLANTIS_GH_APP_KEY_PEM' "$rendered"
grep -q 'ATLANTIS_GH_WEBHOOK_SECRET' "$rendered"
grep -q 'name: atlantis-pilot-backend' "$rendered"
grep -q 'name: atlantis-aiostreams-provider' "$rendered"
grep -q 'ATLANTIS_AIOSTREAMS_S3_ACCESS_KEY_ID' "$rendered"
grep -q 'APP_AIOSTREAMS_TERRAFORM_PASSWORD' "$rendered"
grep -q 'APP_TORBOX_API_KEY' "$rendered"
grep -q 'AWS_ACCESS_KEY_ID' "$rendered"
grep -q 'AWS_SECRET_ACCESS_KEY' "$rendered"
grep -q 'AWS_REGION' "$rendered"
grep -q 'homelab-atlantis-pilot-tfstate' "$rendered"
grep -q 'axnvxxurxefp.compat.objectstorage.eu-paris-1.oraclecloud.com' "$rendered"
grep -q 'get.opentofu.org' "$rendered"
grep -q 'releases.hashicorp.com' "$rendered"
grep -q 'release-assets.githubusercontent.com' "$rendered"
grep -q 'fsGroupChangePolicy: Always' "$rendered"
if grep -q 'argocd.argoproj.io/sync-options: Force=true,Replace=true' "$rendered" || grep -q 'name: repair-data-ownership' "$rendered" || grep -q 'runAsUser: 0' "$rendered"; then
  echo "Atlantis PVC repair must remain compatible with Pod Security restricted" >&2
  exit 1
fi
grep -q 'runAsUser: 100' "$rendered"
if grep -q 'runAsUser: 1000' "$rendered"; then
  echo "Atlantis container must not run as image-incompatible UID 1000" >&2
  exit 1
fi
grep -q -- '- --gh-app-id=5416988' "$rendered"
grep -q -- '- --gh-app-installation-id=173903025' "$rendered"
grep -q -- '- --enable-policy-checks' "$rendered"
if grep -Eq 'name: ATLANTIS_GH_APP_(ID|INSTALLATION_ID)' "$rendered"; then
  echo "GitHub App integer identifiers must be passed as CLI flags" >&2
  exit 1
fi
if grep -Eq 'value: "[0-9]+\.[0-9]+e\+[0-9]+"' "$rendered"; then
  echo "scientific notation is forbidden for GitHub App identifiers" >&2
  exit 1
fi
grep -q 'github.com/SmadjaPaul/homelab-infra' "$rendered"
grep -q 'workflow: atlantis-deny' "$rendered"
grep -q 'repo_config_file: .atlantis/plan-only.yaml' "$rendered"
grep -q 'branch: /^main$/' "$rendered"
grep -q 'plan_requirements: \[mergeable, undiverged\]' "$rendered"
grep -q 'apply_requirements: \[mergeable, undiverged\]' "$rendered"
grep -q 'import_requirements: \[approved, mergeable, undiverged\]' "$rendered"
if grep -q 'test "\$ATLANTIS_PR_APPROVED" = "true"' "$rendered"; then
  echo "plan workflow must not require GitHub approval" >&2
  exit 1
fi
grep -q 'path: /etc/atlantis/conftest' "$rendered"
grep -q 'policy_check: true' "$rendered"
grep -q 'name: TF_DATA_DIR' "$rendered"
grep -q '          - show' "$rendered"
grep -q 'atlantis-pilot-bounded-change' "$rendered"
grep -q 'Verify before Atlantis may automerge' "$rendered"
grep -q '          - apply' "$rendered"
grep -q 'init -input=false -reconfigure' "$rendered"
# State verification must be an apply-workflow run step, never a post-hook.
if grep -q 'post_workflow_hooks:' k8s/poc/atlantis-plan-only/values.yaml; then
  echo "state verification must run before automerge" >&2
  exit 1
fi
grep -q 'CHECKOUT_ROOT="$(cd "$DIR/../.." && pwd)"' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'aiostreams_configuration.family' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'Verify before Atlantis may automerge' k8s/poc/atlantis-plan-only/values.yaml
# Native apply must precede the state check.
python3 - <<'PY'
from pathlib import Path
s=Path("k8s/poc/atlantis-plan-only/values.yaml").read_text()
a=s.index("    atlantis-plan-only:")
b=s.index("      import:",a)
apply=s[s.index("      apply:",a):b]
assert apply.index("          - apply\n") < apply.index("Verify before Atlantis may automerge")
assert "state list" in apply
assert "COMMAND_HAS_ERRORS" not in apply
assert "OUTPUT_STATUS_FILE" not in apply
PY
grep -q 'name: atlantis-pilot-conftest' "$rendered"
grep -q 'pilot.rego:' "$rendered"
grep -q 'allowed_pilot_actions' k8s/poc/atlantis-plan-only/policies/pilot.rego
grep -q 'not action in allowed_pilot_actions' k8s/poc/atlantis-plan-only/policies/pilot.rego
grep -q 'allowed_aiostreams_actions' k8s/poc/atlantis-plan-only/policies/pilot.rego
grep -q 'not action in allowed_aiostreams_actions' k8s/poc/atlantis-plan-only/policies/pilot.rego
grep -q 'name: atlantis-github-iac' "$rendered"
grep -q 'kind: ClusterSecretStore' "$rendered"
grep -q 'name: doppler-cluster' "$rendered"
grep -q 'name: atlantis-github-repository-safety' "$rendered"
grep -q 'github-repository-safety.rego:' "$rendered"
grep -q 'github-atlantis-guard.sh:' "$rendered"
grep -q 'fc66d3b6d8c59581cf3f771b33766d1ebcb042a3' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
grep -q '79522bce630cad360a6ebe3bf6f1ebc965379cb9' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
grep -q '37cf4ab1d01f0228a305d54f458e7a9c51930127' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
grep -q 'scripts/architecture-check.sh' "$rendered"
grep -q 'terraform/cloudflare/modules/access/README.md' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
if grep -Eq 'terraform/\*/modules/\*/README\.md|security-headers/variables\.tf' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh; then
  echo "Atlantis GitHub admission must not carry a broad README glob or Terraform source exception" >&2
  exit 1
fi
grep -q 'registry.terraform.io' "$rendered"
grep -q 'TF_DATA_DIR' "$rendered"
if grep -q 'subPath: pilot.rego' "$rendered"; then
  echo "Conftest policy must be mounted as a directory for Atlantis" >&2
  exit 1
fi
grep -q 'allowed_overrides: \[\]' "$rendered"
grep -q 'allow_custom_workflows: false' "$rendered"

# Execute the exact server-owned AIOStreams verifier against isolated fake state.
# The positive fixture contains the null write-only markers emitted by OpenTofu;
# the negative fixture contains a non-null credential and must fail closed.
fixture_root="$(mktemp -d)"
verify_start="$(grep -n '^          # Verify before Atlantis may automerge' k8s/poc/atlantis-plan-only/values.yaml | cut -d: -f1)"
verify_end="$(grep -n '^      import:' k8s/poc/atlantis-plan-only/values.yaml | awk -F: -v start="$verify_start" '$1 > start { print $1; exit }')"
verify_source="$fixture_root/verify.sh"
sed -n "$((verify_start + 1)),$((verify_end - 1))p" k8s/poc/atlantis-plan-only/values.yaml |
  sed '1d;s/^              //' >"$verify_source"

run_verifier_case() {
  local name="$1"
  local state="$2"
  local expected_status="$3"
  local case_root="$fixture_root/$name"
  local fake_bin="$case_root/bin"
  local project_dir="$case_root/repo/terraform/aiostreams"
  local transformed="$case_root/verify.sh"
  mkdir -p "$fake_bin" "$project_dir"
  : >"$project_dir/backend.tf"
  : >"$project_dir/main.tf"
  printf '%s' "$state" >"$case_root/state.json"
  cat >"$fake_bin/tofu1.13.1" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  init) exit 0 ;;
  workspace) test "${2:-}" = show; printf 'default\n' ;;
  state)
    case "${2:-}" in
      list) printf 'aiostreams_configuration.family\n' ;;
      pull) cat "$FAKE_STATE_FILE" ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$fake_bin/tofu1.13.1"
  sed \
    -e "s#TOFU=/atlantis-data/bin/tofu1.13.1#TOFU=$fake_bin/tofu1.13.1#g" \
    -e '/export AWS_ACCESS_KEY_ID=/d' \
    -e '/export AWS_SECRET_ACCESS_KEY=/d' \
    -e '/export AWS_REGION=/d' \
    -e '/export AIOSTREAMS_PASSWORD=/d' \
    "$verify_source" >"$transformed"
  chmod +x "$transformed"
  set +e
  (
    export DIR="$project_dir"
    export PROJECT_NAME=aiostreams
    export HEAD_COMMIT=fixture
    export FAKE_STATE_FILE="$case_root/state.json"
    export PATH="$fake_bin:$PATH"
    bash "$transformed"
  ) >"$case_root/output" 2>&1
  local actual_status="$?"
  set -e
  test "$actual_status" = "$expected_status" || {
    cat "$case_root/output" >&2
    echo "unexpected verifier status for $name: $actual_status" >&2
    exit 1
  }
}

run_verifier_case positive \
  '{"password_wo":null,"credentials_json_wo":null,"resources":[]}' 0
run_verifier_case negative \
  '{"password_wo":"unexpected-value","credentials_json_wo":null}' 1
rm -rf "$fixture_root"

deny_line="$(grep -n '^    - id: /\.\*/' k8s/poc/atlantis-plan-only/values.yaml | head -1 | cut -d: -f1)"
exact_line="$(grep -n '^    - id: github.com/SmadjaPaul/homelab-infra' k8s/poc/atlantis-plan-only/values.yaml | head -1 | cut -d: -f1)"
test -n "$deny_line"
test -n "$exact_line"
test "$deny_line" -lt "$exact_line"

if grep -Eq '(:|@)latest(["[:space:]]|$)|:main(["[:space:]]|$)' "$rendered"; then
  echo "unversioned Atlantis image or chart artifact detected" >&2
  exit 1
fi

if grep -Eiq 'value:[[:space:]]*infrastructure/prd|name:[[:space:]]*OCI_S3|allowForkPRs:[[:space:]]*true|allowDraftPRs:[[:space:]]*true' "$rendered"; then
  echo "operator secret surface or unsafe PR setting detected" >&2
  exit 1
fi

echo "Atlantis pilot apply manifests: render and security assertions passed"
