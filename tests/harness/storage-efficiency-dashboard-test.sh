#!/usr/bin/env bash
set -euo pipefail

dashboard='k8s/infrastructure/monitoring/prometheus-stack/grafana-storage-efficiency.yaml'
[[ -f "$dashboard" ]] || { echo "missing $dashboard" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

json="$(yq -r '.data["storage-efficiency.json"]' "$dashboard")"
jq -e '
  .uid == "homelab-storage-efficiency" and
  .title == "Homelab Storage Efficiency" and
  .editable == false and
  (.panels | length == 9) and
  (([.panels[].id] | length) == ([.panels[].id] | unique | length)) and
  ([.panels[] | select(.type != "text") | .fieldConfig.defaults.unit] | all(. != null and length > 0)) and
  ([.panels[] | select(.type == "timeseries") | .targets[]] | all(has("legendFormat"))) and
  ([.panels[].targets[]?.expr] | all(test("or vector\\(0\\)") | not))
' <<< "$json" >/dev/null

echo 'storage efficiency dashboard contract: PASS'
