#!/usr/bin/env bash
set -euo pipefail

# Static chart contract only. It does not contact Kubernetes, inspect a Secret,
# or claim restart/reconciliation proof.

rendered_values="$(yq '.spec.source.helm.valuesObject' \
  k8s/optional/personal-ai-2026/librechat/application.yaml)"
rendered_chart="$(printf '%s\n' "$rendered_values" | \
  helm template librechat \
    oci://ghcr.io/librechat-ai/librechat-chart/librechat \
    --version 3.0.0 \
    --namespace librechat \
    --values - 2>/dev/null | \
  sed -E 's/^(  (mongodb-root-password|mongodb-passwords|mongodb-replica-set-key):).*/\1 REDACTED/')"

assert_contains() {
  local needle="$1"
  grep -F "$needle" <<<"$rendered_chart" >/dev/null || {
    printf 'LIBRECHAT_MONGODB_AUTH_CONTRACT=FAIL\n'
    exit 1
  }
}

assert_contains 'name: librechat-mongodb'
assert_contains 'key: mongodb-root-password'
assert_contains 'name: "librechat-mongodb"'
assert_contains 'value: mongodb://root:$(MONGODB_ROOT_PASSWORD)@librechat-mongodb.librechat.svc.cluster.local:27017/LibreChat?authSource=admin'
assert_contains 'helm.sh/resource-policy: "keep"'

if grep -Eq 'MONGODB_ROOT_PASSWORD:[[:space:]]+[^$]|mongodb://[^:]+:[^$]' <<<"$rendered_chart"; then
  printf 'LIBRECHAT_MONGODB_AUTH_CONTRACT=FAIL\n'
  exit 1
fi

printf 'LIBRECHAT_MONGODB_AUTH_CONTRACT=PASS\n'
