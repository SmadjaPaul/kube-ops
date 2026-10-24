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
grep -q 'Verify the selected state after Atlantis apply' "$rendered"
grep -q '          - apply' "$rendered"
grep -q 'name: atlantis-pilot-conftest' "$rendered"
grep -q 'pilot.rego:' "$rendered"
grep -q 'name: atlantis-github-iac' "$rendered"
grep -q 'kind: ClusterSecretStore' "$rendered"
grep -q 'name: doppler-cluster' "$rendered"
grep -q 'name: atlantis-github-repository-safety' "$rendered"
grep -q 'github-repository-safety.rego:' "$rendered"
grep -q 'github-atlantis-guard.sh:' "$rendered"
grep -q 'scripts/architecture-check.sh' "$rendered"
grep -q 'terraform/\*/modules/\*/README.md' k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
grep -q 'registry.terraform.io' "$rendered"
grep -q 'TF_DATA_DIR' "$rendered"
if grep -q 'subPath: pilot.rego' "$rendered"; then
  echo "Conftest policy must be mounted as a directory for Atlantis" >&2
  exit 1
fi
grep -q 'allowed_overrides: \[\]' "$rendered"
grep -q 'allow_custom_workflows: false' "$rendered"

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
