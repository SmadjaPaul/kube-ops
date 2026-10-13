#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/k8s/applications/platform/mastra-factory/deployment.yaml"

path="$(yq -r '.spec.template.spec.containers[0].readinessProbe.httpGet.path // ""' "$manifest")"
port="$(yq -r '.spec.template.spec.containers[0].readinessProbe.httpGet.port // ""' "$manifest")"

[[ "$path" == "/health" ]] || {
  printf 'ASSERTION_FAILED readiness_path=%s\n' "$path" >&2
  exit 1
}
[[ "$port" == "http" ]] || {
  printf 'ASSERTION_FAILED readiness_port=%s\n' "$port" >&2
  exit 1
}

printf 'MASTRA_FACTORY_READINESS=PASS path=%s port=%s\n' "$path" "$port"
