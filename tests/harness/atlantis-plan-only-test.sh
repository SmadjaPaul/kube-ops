#!/usr/bin/env bash
set -euo pipefail

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

kustomize build --enable-helm k8s/poc/atlantis-plan-only >"$rendered"

grep -q 'ghcr.io/runatlantis/atlantis:v0.48.1@sha256:42bde40e38ec7b89f02a2968b4b1b74b990121eb8768d0a7de7caad125344298' "$rendered"
grep -q 'chart: atlantis-6.16.1' "$rendered"
grep -q 'ATLANTIS_ALLOW_COMMANDS' "$rendered"
grep -q 'value: version,plan,policy_check' "$rendered"
grep -q 'name: ATLANTIS_DISABLE_APPLY' "$rendered"
grep -q 'value: "true"' "$rendered"
grep -q 'name: atlantis-webhook' "$rendered"
grep -q 'value: /events' "$rendered"
grep -q 'name: atlantis-github-app' "$rendered"
grep -q 'key.pem' "$rendered"
grep -q 'ATLANTIS_GH_APP_KEY_PEM' "$rendered"
grep -q 'ATLANTIS_GH_WEBHOOK_SECRET' "$rendered"
grep -q 'maxUnavailable: 1' "$rendered"
grep -q -- '- --gh-app-id=5416988' "$rendered"
grep -q -- '- --gh-app-installation-id=173903025' "$rendered"
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
grep -q 'plan_requirements: \[approved, mergeable, undiverged\]' "$rendered"
grep -q 'apply_requirements: \[approved, mergeable, undiverged\]' "$rendered"
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

if grep -Eiq 'value:[[:space:]]*infrastructure/prd|name:[[:space:]]*OCI_S3|allowForkPRs:[[:space:]]*true|allowDraftPRs:[[:space:]]*true|disableApply:[[:space:]]*false' "$rendered"; then
  echo "operator secret surface or unsafe PR setting detected" >&2
  exit 1
fi

echo "Atlantis plan-only manifests: render and security assertions passed"
