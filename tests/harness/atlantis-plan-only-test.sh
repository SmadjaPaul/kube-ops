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

if grep -Eq '(:|@)latest(["[:space:]]|$)|:main(["[:space:]]|$)' "$rendered"; then
  echo "unversioned Atlantis image or chart artifact detected" >&2
  exit 1
fi

echo "Atlantis plan-only manifests: render and security assertions passed"
