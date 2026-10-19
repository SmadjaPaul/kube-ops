#!/usr/bin/env bash

set -euo pipefail

catalog="k8s/infrastructure/monitoring/prometheus-stack/grafana-catalog.yaml"
folders=(
  '00 — Overview'
  '10 — Infrastructure'
  '20 — Kubernetes'
  '30 — Observability'
  '40 — Software Factory'
  '50 — Data Platform'
  '90 — Advanced Diagnostics'
)
expected_titles=(
  'Platform Overview'
  'Host & Hardware'
  'Storage & Backups'
  'Cluster & Workloads'
  'Networking'
  'Telemetry Pipeline'
  'Factory Operations'
  'Factory Performance'
  'dbt V2 Operations'
  'Data Quality'
)

[[ -f "$catalog" ]] || { echo "missing $catalog" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

catalog_json="$(mktemp)"
trap 'rm -f "$catalog_json"' EXIT
yq -o=json eval-all '[select(.kind == "ConfigMap")]' "$catalog" >"$catalog_json"

count="$(jq 'length' "$catalog_json")"
[[ "$count" -eq 11 ]] || { echo "expected 11 curated dashboards, got $count" >&2; exit 1; }

jq -e '
  (map(.metadata.labels.grafana_dashboard == "1") | all) and
  ((map(.metadata.annotations.grafana_folder) | unique | sort) == ([
    "00 — Overview",
    "10 — Infrastructure",
    "20 — Kubernetes",
    "30 — Observability",
    "40 — Software Factory",
    "50 — Data Platform",
    "90 — Advanced Diagnostics"
  ] | sort)) and
  (map(.data | to_entries | length == 1) | all)
' "$catalog_json" >/dev/null

jq -e '
  [.[].data[] | fromjson] as $dashboards |
  (($dashboards | map(.uid) | length) == ($dashboards | map(.uid) | unique | length)) and
  ($dashboards | all(
    .uid and .title and .description and
    (.tags | type == "array" and length >= 2 and length <= 4) and
    (.tags | all(. as $tag | ["platform","infrastructure","kubernetes","observability","factory","data-platform","storage","network","security","advanced"] | index($tag) != null)) and
    (.panels | type == "array" and length > 0) and
    (.links | type == "array" and length > 0)
  ))
' "$catalog_json" >/dev/null

for title in "${expected_titles[@]}"; do
  jq -e --arg title "$title" '[.[].data[] | fromjson | select(.title == $title)] | length == 1' "$catalog_json" >/dev/null || {
    echo "missing expected dashboard: $title" >&2
    exit 1
  }
done

if rg -n -i 'nodes-aix|nodes-darwin|loki-dashboards|bloom-build|bloom-gateway|defaultDashboardsEnabled: true' \
  k8s/infrastructure/monitoring/prometheus-stack/grafana-catalog.yaml; then
  echo "disabled upstream catalogue leaked into curated catalogue" >&2
  exit 1
fi

echo "grafana dashboard contract: PASS ($count dashboards, stable UIDs, required folders and metadata)"
