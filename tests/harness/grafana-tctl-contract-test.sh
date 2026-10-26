#!/usr/bin/env bash

set -euo pipefail

catalog='k8s/infrastructure/monitoring/prometheus-stack/grafana-catalog.yaml'
[[ -f "$catalog" ]] || { echo "missing $catalog" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

json="$(mktemp)"
trap 'rm -f "$json"' EXIT
yq -r 'select(.metadata.name == "grafana-host-hardware-dashboard") | .data["host-hardware.json"]' "$catalog" >"$json"

jq -e '
  .uid == "homeops-edge-boot-io" and
  .title == "Host & Hardware" and
  ([.panels[].id] | length) == ([.panels[].id] | unique | length) and
  ([.panels[].title] | index("Tctl actuel") != null) and
  ([.panels[].title] | index("Tctl maximum récent (24h)") != null) and
  ([.panels[].title] | index("Température physique Tctl (k10temp)") != null) and
  ([.panels[] | select(.title == "Tctl actuel") | .targets[].expr] |
    all(contains("node_hwmon_temp_celsius") and
        contains("job=\"proxmox-host\"") and
        contains("chip=\"pci0000:00_0000:00:18_3\"") and
        contains("sensor=\"temp1\""))) and
  ([.panels[] | select(.title == "Tctl maximum récent (24h)") | .targets[].expr] |
    all(startswith("max_over_time(") and contains("node_hwmon_temp_celsius"))) and
  ([.panels[] | select(.title == "Température physique Tctl (k10temp)") | .targets[].expr] |
    all(contains("node_hwmon_temp_celsius") and
        contains("chip=\"pci0000:00_0000:00:18_3\"") and
        contains("sensor=\"temp1\""))) and
  ([.panels[] | select(.title | test("Tctl|Température")) | .targets[].expr] |
    all(test("node_hwmon_fan_rpm") | not))
' "$json" >/dev/null

echo 'grafana Tctl contract: PASS (exact sensor, current/evolution/max panels, no fan RPM)'
