#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/k8s/applications/web/trilium/deployment.yaml"

for probe in startupProbe livenessProbe readinessProbe; do
  path="$(yq -r ".spec.template.spec.containers[0].${probe}.httpGet.path" "$manifest")"
  [[ "$path" == '/api/health-check' ]] || {
    printf 'ASSERTION_FAILED probe=%s path=%s\n' "$probe" "$path" >&2
    exit 1
  }
done

failure_threshold="$(yq -r '.spec.template.spec.containers[0].startupProbe.failureThreshold' "$manifest")"
[[ "$failure_threshold" == '24' ]] || {
  printf 'ASSERTION_FAILED startupFailureThreshold=%s\n' "$failure_threshold" >&2
  exit 1
}

printf '%s\n' 'TRILIUM_PROBE_CONTRACT_TEST=PASS'
