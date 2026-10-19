#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
longhorn_root="$repo_root/k8s/infrastructure/storage/longhorn"

rendered="$(kustomize build --enable-helm "$longhorn_root")"

printf '%s\n' "$rendered" |
  yq -e '
    select(.kind == "ServiceMonitor" and .metadata.name == "longhorn-prometheus-servicemonitor") |
    .metadata.namespace == "longhorn-system" and
    .metadata.labels.release == "kube-prometheus-stack" and
    .spec.selector.matchLabels.app == "longhorn-manager" and
    .spec.namespaceSelector.matchNames[0] == "longhorn-system" and
    .spec.endpoints[0].port == "manager" and
    .spec.endpoints[0].interval == "30s" and
    .spec.endpoints[0].scrapeTimeout == "10s"
  ' >/dev/null

printf '%s\n' 'LONGHORN_SERVICEMONITOR_CONTRACT=PASS'
