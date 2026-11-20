#!/usr/bin/env bash

set -euo pipefail

command -v yq >/dev/null 2>&1 || {
  echo "ERROR: yq is required" >&2
  exit 2
}

values="k8s/infrastructure/security/gatekeeper/values.yaml"

yq -e '
  .auditInterval == 60 and
  .constraintViolationsLimit == 20 and
  .auditFromCache == true and
  .audit.resources.requests.memory == "512Mi" and
  .audit.resources.limits.memory == "1Gi" and
  ((.audit | has("auditInterval")) | not) and
  ((.audit | has("constraintViolationsLimit")) | not) and
  ((.audit | has("auditFromCache")) | not)
' "$values" >/dev/null

printf '%s\n' 'GATEKEEPER_AUDIT_VALUES_CONTRACT_TEST=PASS'
