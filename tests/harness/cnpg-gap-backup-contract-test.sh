#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_backup() {
  local root="$1"
  local namespace="$2"
  local name="$3"
  local cluster="$4"
  local store="$5"
  local rendered="$tmp/${namespace}.yaml"

  kustomize build "$repo_root/$root" >"$rendered"
  yq eval-all -o=json 'select(.kind == "Backup")' "$rendered" |
    jq -s -e --arg namespace "$namespace" --arg name "$name" \
      --arg cluster "$cluster" --arg store "$store" '
      map(select(
        .apiVersion == "postgresql.cnpg.io/v1" and
        .metadata.namespace == $namespace and
        .metadata.name == $name and
        .metadata.labels["backup.smadja.dev/purpose"] == "gap-remediation" and
        .spec.cluster.name == $cluster and
        .spec.method == "plugin" and
        .spec.pluginConfiguration.name == "barman-cloud.cloudnative-pg.io" and
        .spec.pluginConfiguration.parameters.barmanObjectName == $store
      )) | length == 1
    ' >/dev/null
}

check_backup \
  k8s/applications/media/immich/immich-server \
  immich \
  immich-postgresql-gap-remediation-20261019 \
  immich-postgresql \
  immich-hetzner-store

check_backup \
  k8s/applications/catalog/sure \
  sure \
  sure-postgresql-gap-remediation-20261019 \
  sure-postgresql \
  sure-hetzner-store

echo "CNPG_GAP_BACKUP_CONTRACT=PASS"
