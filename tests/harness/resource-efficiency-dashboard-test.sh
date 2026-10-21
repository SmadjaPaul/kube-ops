#!/usr/bin/env bash
set -euo pipefail

dashboard='k8s/infrastructure/monitoring/prometheus-stack/grafana-resource-efficiency.yaml'
[[ -f "$dashboard" ]] || { echo "missing $dashboard" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

json="$(mktemp)"
trap 'rm -f "$json"' EXIT
yq -r '.data["resource-efficiency.json"]' "$dashboard" >"$json"

jq -e '
  .uid == "cluster-resource-efficiency" and
  .editable == false and
  .refresh == "5m" and
  (.panels | length == 14) and
  (([.panels[].id] | length) == ([.panels[].id] | unique | length)) and
  ([.panels[].targets[]?.expr] | all(test("or vector\\(0\\)") | not))
' "$json" >/dev/null

echo 'resource efficiency dashboard contract: PASS'
