#!/usr/bin/env bash

set -euo pipefail

catalog="k8s/infrastructure/monitoring/prometheus-stack/grafana-catalog.yaml"
factory_optio="k8s/infrastructure/monitoring/prometheus-stack/grafana-factory-optio.yaml"
agentgateway="k8s/infrastructure/monitoring/prometheus-stack/grafana-agentgateway.yaml"
agentgateway_app="k8s/applications/platform/agentgateway/resources.yaml"
agentgateway_scrape="k8s/infrastructure/monitoring/scrape-targets/agentgateway-podmonitor.yaml"
values="k8s/infrastructure/monitoring/prometheus-stack/values.yaml"
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
  'Factory Optio'
  'Agentgateway'
)

[[ -f "$catalog" ]] || { echo "missing $catalog" >&2; exit 1; }
[[ -f "$factory_optio" ]] || { echo "missing $factory_optio" >&2; exit 1; }
[[ -f "$agentgateway" ]] || { echo "missing $agentgateway" >&2; exit 1; }
[[ -f "$agentgateway_app" ]] || { echo "missing $agentgateway_app" >&2; exit 1; }
[[ -f "$agentgateway_scrape" ]] || { echo "missing $agentgateway_scrape" >&2; exit 1; }
[[ -f "$values" ]] || { echo "missing $values" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

[[ "$(yq '.grafana.sidecar.dashboards.searchNamespace' "$values")" == "monitoring" ]] || {
  echo "dashboard sidecar must be scoped to monitoring" >&2
  exit 1
}
[[ "$(yq '.grafana.sidecar.dashboards.watchMethod' "$values")" == "SLEEP" ]] || {
  echo "dashboard sidecar must use SLEEP reconciliation" >&2
  exit 1
}

catalog_json="$(mktemp)"
factory_json="$(mktemp)"
agentgateway_json="$(mktemp)"
dashboards_json="$(mktemp)"
factory_dashboard_json="$(mktemp)"
agentgateway_dashboard_json="$(mktemp)"
agentgateway_app_json="$(mktemp)"
agentgateway_config_yaml="$(mktemp)"
agentgateway_podmonitor_json="$(mktemp)"
trap 'rm -f "$catalog_json" "$factory_json" "$agentgateway_json" "$dashboards_json" \
  "$factory_dashboard_json" "$agentgateway_dashboard_json" "$agentgateway_app_json" \
  "$agentgateway_config_yaml" "$agentgateway_podmonitor_json"' EXIT

yq -o=json eval-all '[select(.kind == "ConfigMap")]' "$catalog" >"$catalog_json"
yq -o=json eval-all '[select(.kind == "ConfigMap")]' "$factory_optio" >"$factory_json"
yq -o=json eval-all '[select(.kind == "ConfigMap")]' "$agentgateway" >"$agentgateway_json"
# The whole catalogue: the curated ConfigMaps plus the Factory Optio and the
# Agentgateway ones.
jq -s '.[0] + .[1] + .[2]' "$catalog_json" "$factory_json" "$agentgateway_json" >"$dashboards_json"

count="$(jq 'length' "$catalog_json")"
[[ "$count" -eq 11 ]] || { echo "expected 11 curated dashboards, got $count" >&2; exit 1; }

factory_count="$(jq 'length' "$factory_json")"
[[ "$factory_count" -eq 1 ]] || {
  echo "expected 1 Factory Optio dashboard, got $factory_count" >&2
  exit 1
}

agentgateway_count="$(jq 'length' "$agentgateway_json")"
[[ "$agentgateway_count" -eq 1 ]] || {
  echo "expected 1 Agentgateway dashboard, got $agentgateway_count" >&2
  exit 1
}

total="$(jq 'length' "$dashboards_json")"
[[ "$total" -eq 13 ]] || { echo "expected 13 dashboards in the catalogue, got $total" >&2; exit 1; }

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
' "$dashboards_json" >/dev/null

jq -e '
  [.[].data[] | fromjson] as $dashboards |
  ($dashboards | map(.uid)) as $uids |
  (($dashboards | map(.uid) | length) == ($dashboards | map(.uid) | unique | length)) and
  ($dashboards | all(
    .uid and .title and .description and
    (.tags | type == "array" and length >= 2 and length <= 4) and
    (.tags | all(. as $tag | ["platform","infrastructure","kubernetes","observability","factory","data-platform","storage","network","security","advanced"] | index($tag) != null)) and
    (.panels | type == "array" and length > 0) and
    (.links | type == "array" and length > 0) and
    ([.links[]?.url | select(startswith("/d/")) | split("/")[2]] as $links |
      ($links | all(.[]; . as $uid | $uids | index($uid) != null))) and
    ([.panels[] | select(.type != "text") | .fieldConfig.defaults.unit] | all(. != null and length > 0)) and
    ([.panels[] | select(.type == "timeseries") | .targets[]] | all(has("legendFormat"))) and
    ([.panels[] | select(.type == "timeseries") | .options.legend] | all(. != null))
  ))
' "$dashboards_json" >/dev/null

for title in "${expected_titles[@]}"; do
  jq -e --arg title "$title" '[.[].data[] | fromjson | select(.title == $title)] | length == 1' "$dashboards_json" >/dev/null || {
    echo "missing expected dashboard: $title" >&2
    exit 1
  }
done

# --- Factory Optio (PLT-528) -------------------------------------------------
# The dashboard reads the Optio API metrics (0.26.4), scraped from the namespace
# `optio`. It must stay a read-only view of series that upstream really emits:
# the metric names and the labels below come from the upstream source
# (apps/api/src/telemetry/attributes.ts and apps/api/src/telemetry/metrics.ts of
# Optio 0.26.4), never from a guess.

jq -e '
  .[0].kind == "ConfigMap" and
  .[0].apiVersion == "v1" and
  .[0].metadata.name == "grafana-factory-optio-dashboard" and
  .[0].metadata.namespace == "monitoring" and
  .[0].metadata.labels.grafana_dashboard == "1" and
  .[0].metadata.annotations.grafana_folder == "40 — Software Factory" and
  (.[0].data | to_entries | length == 1) and
  (.[0].data | keys[0] | endswith(".json"))
' "$factory_json" >/dev/null || {
  echo "the Factory Optio dashboard must be one grafana_dashboard ConfigMap of the 40 — Software Factory folder" >&2
  exit 1
}

jq -r '.[0].data[]' "$factory_json" >"$factory_dashboard_json"

jq -e '
  .uid == "factory-optio" and
  .title == "Factory Optio" and
  (.description | type == "string" and length > 0) and
  .editable == false and
  (.panels | type == "array" and length > 0) and
  (([.panels[].id] | length) == ([.panels[].id] | unique | length)) and
  ([.panels[] | select(.type == "text")] | length == 1) and
  ([.panels[] | select(.type == "text") | .options.mode] | all(. == "markdown")) and
  ([.panels[] | select(.title == "Estimated cost by model (Optio estimate, not an invoice)")] | length == 1) and
  ([.panels[] | select(.type == "text") | .options.content] | join(" ") |
    test("MiniMax") and test("Agentgateway") and test("Linear"))
' "$factory_dashboard_json" >/dev/null || {
  echo "the Factory Optio dashboard must carry its uid, its title, a text panel with the limits and the cost panel" >&2
  exit 1
}

# Every metric family the ticket asks for must be queried.
for metric in optio_queue_depth optio_active_tasks optio_pod_count optio_tasks_total \
  optio_task_duration_seconds optio_task_tokens optio_task_cost_usd; do
  jq -e --arg metric "$metric" \
    '[.panels[].targets[]?.expr | select(test($metric))] | length > 0' \
    "$factory_dashboard_json" >/dev/null || {
    echo "the Factory Optio dashboard does not query $metric" >&2
    exit 1
  }
done

# No invented metric, no invented label: the names and the labels below are the
# ones the deployed upstream really emits. Prometheus adds the scrape labels,
# `le` comes from the histogram exposition.
#
# Optio 0.26.4 (apps/api/src/telemetry/attributes.ts and
# apps/api/src/telemetry/metrics.ts).
#
# Agentgateway v1.6.0 (crates/agentgateway/src/telemetry/metrics.rs of the
# deployed sources): GenAILabelsTokenUsage (gen_ai_token_type) flattened with
# GenAILabels (gen_ai_operation_name, gen_ai_system, gen_ai_request_model,
# gen_ai_response_model), RouteIdentifier (bind, gateway, listener, route,
# route_rule) and the custom metric fields of the gateway configuration.
# `api_key` is one of those custom fields: it is not native to the gateway,
# the repository declares it (config.metrics.fields.add).
upstream_labels() { # <metric> -> the labels it carries
  case "$1" in
    optio_tasks_total) echo "state agent_type model repo_url" ;;
    optio_task_duration_seconds) echo "terminal_state agent_type" ;;
    optio_task_cost_usd) echo "agent_type model repo_url" ;;
    optio_task_tokens) echo "agent_type model repo_url direction" ;;
    optio_queue_depth) echo "state" ;;
    optio_active_tasks) echo "" ;;
    optio_pod_count) echo "state" ;;
    optio_pr_watch_cycle_duration_seconds) echo "" ;;
    optio_state_transitions_total) echo "from to trigger" ;;
    optio_worker_job_duration_seconds) echo "worker success" ;;
    optio_pod_health_events_total) echo "event_type repo" ;;
    optio_webhook_deliveries_total) echo "event success" ;;
    agentgateway_gen_ai_client_token_usage)
      echo "gen_ai_token_type gen_ai_operation_name gen_ai_system gen_ai_request_model gen_ai_response_model bind gateway listener route route_rule api_key" ;;
    agentgateway_requests_total)
      echo "backend protocol method status reason bind gateway listener route route_rule api_key" ;;
    *) return 1 ;;
  esac
}

upstream_metric() { # <series> -> the metric a Prometheus series belongs to
  local series="$1" candidate
  if upstream_labels "$series" >/dev/null 2>&1; then
    echo "$series"
    return 0
  fi
  # A histogram exposes <name>_bucket, <name>_sum and <name>_count.
  for suffix in _bucket _sum _count; do
    candidate="${series%"$suffix"}"
    if [[ "$candidate" != "$series" ]] && upstream_labels "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

scrape_labels="namespace job instance pod service endpoint le"

check_no_invented_label() { # <dashboard json> <metric prefix> <dashboard name> <upstream>
  local dashboard="$1" prefix="$2" who="$3" upstream="$4"
  local expr series_list metric used_labels allowed label
  local -a series_array
  while IFS= read -r expr; do
    [[ -n "$expr" ]] || continue
    series_list="$(printf '%s\n' "$expr" | grep -oE "${prefix}[a-z0-9_]+" | sort -u || true)"
    [[ -n "$series_list" ]] || {
      echo "the $who dashboard has an expression without a metric: $expr" >&2
      exit 1
    }
    mapfile -t series_array <<<"$series_list"
    [[ "${#series_array[@]}" -eq 1 ]] || {
      echo "an expression of the $who dashboard must query one metric family: $expr" >&2
      exit 1
    }
    metric="$(upstream_metric "${series_array[0]}")" || {
      echo "$upstream does not emit the metric ${series_array[0]} (expression: $expr)" >&2
      exit 1
    }
    # The labels of the selectors (label="value") and of the groupings (by (label)).
    used_labels="$(printf '%s\n' "$expr" |
      grep -oE '[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(=~|!~|!=|=)[[:space:]]*"' |
      sed -E 's/[[:space:]]*(=~|!~|!=|=).*$//' | sort -u || true)"
    used_labels="$used_labels $(printf '%s\n' "$expr" |
      grep -oE 'by[[:space:]]*\([^)]*\)' |
      sed -E 's/^by[[:space:]]*\(//; s/\)$//' | tr ',' '\n' | tr -d ' \t' | sort -u || true)"
    allowed=" $(upstream_labels "$metric") $scrape_labels "
    for label in $used_labels; do
      [[ -n "$label" ]] || continue
      [[ "$allowed" == *" $label "* ]] || {
        echo "the label $label is not emitted by $metric (expression: $expr)" >&2
        exit 1
      }
    done
  done <<<"$(jq -r '[.panels[].targets[]?.expr] | .[]' "$dashboard")"
}

check_no_invented_label "$factory_dashboard_json" 'optio_' 'Factory Optio' 'Optio 0.26.4'

# --- Agentgateway (PLT-536) --------------------------------------------------
# The dashboard reads the Prometheus metrics of the gateway itself
# (agentgateway_*), served by the deployed Agentgateway v1.6.0 on /metrics
# (STATS_ADDR, default 0.0.0.0:15020) and scraped from the namespace
# `agentgateway`. The metric names and the labels are the ones the deployed
# version really emits (crates/agentgateway/src/telemetry/metrics.rs of the
# v1.6.0 sources): the token family `agentgateway_gen_ai_client_token_usage`
# and the request counter `agentgateway_requests_total`.
#
# The gateway emits no per-key label of its own: `api_key` is a custom metric
# field that this repository declares in the gateway configuration
# (config.metrics.fields.add -> apiKey.name). The contract below refuses a
# dashboard that uses that label without the declaration, a scrape target that
# does not exist, or a port that the network policy does not open.

jq -e '
  .[0].kind == "ConfigMap" and
  .[0].apiVersion == "v1" and
  .[0].metadata.name == "grafana-agentgateway-dashboard" and
  .[0].metadata.namespace == "monitoring" and
  .[0].metadata.labels.grafana_dashboard == "1" and
  .[0].metadata.annotations.grafana_folder == "40 — Software Factory" and
  (.[0].data | to_entries | length == 1) and
  (.[0].data | keys[0] | endswith(".json"))
' "$agentgateway_json" >/dev/null || {
  echo "the Agentgateway dashboard must be one grafana_dashboard ConfigMap of the 40 — Software Factory folder" >&2
  exit 1
}

jq -r '.[0].data[]' "$agentgateway_json" >"$agentgateway_dashboard_json"

jq -e '
  .uid == "agentgateway" and
  .title == "Agentgateway" and
  (.description | type == "string" and length > 0) and
  .editable == false and
  (.panels | type == "array" and length > 0) and
  (([.panels[].id] | length) == ([.panels[].id] | unique | length)) and
  ([.panels[] | select(.type == "text")] | length == 1) and
  ([.panels[] | select(.type == "text") | .options.mode] | all(. == "markdown")) and
  ([.panels[] | select(.title == "Tokens per API key per day (input / output)")] | length == 1) and
  ([.panels[] | select(.title == "Tokens per model (input / output)")] | length == 1) and
  ([.panels[] | select(.title == "Estimated cost per model (estimation, not an invoice)")] | length == 1) and
  ([.panels[] | select(.title == "Rate of 429 responses")] | length == 1) and
  ([.panels[] | select(.type == "text") | .options.content] | join(" ") |
    test("Agentgateway") and
    test("apiKey.name") and
    test("agentgateway_gen_ai_client_token_usage") and
    test("estimation") and
    test("MiniMax") and
    test("4 USD/M \\| 20 USD/M \\| 0.20 USD/M") and
    test("0 USD/M"))
' "$agentgateway_dashboard_json" >/dev/null || {
  echo "the Agentgateway dashboard must carry its uid, its title, its panels, the limits and the tariff of the estimate" >&2
  exit 1
}

# Every metric family the ticket asks for must be queried.
for metric in agentgateway_gen_ai_client_token_usage agentgateway_requests_total; do
  jq -e --arg metric "$metric" \
    '[.panels[].targets[]?.expr | select(test($metric))] | length > 0' \
    "$agentgateway_dashboard_json" >/dev/null || {
    echo "the Agentgateway dashboard does not query $metric" >&2
    exit 1
  }
done

# The estimate applies the tariff written in the dashboard: the rates of the
# queries and the rates of the text panel must be the same ones.
jq -e '
  [.panels[] | select(.title == "Estimated cost per model (estimation, not an invoice)") | .targets[].expr] as $exprs |
  ($exprs | length == 3) and
  ($exprs | any(test("\\* 4 / 1000000"))) and
  ($exprs | any(test("\\* 20 / 1000000"))) and
  ($exprs | any(test("\\* 0.2 / 1000000")))
' "$agentgateway_dashboard_json" >/dev/null || {
  echo "the estimated cost of the Agentgateway dashboard must apply the tariff written in the dashboard" >&2
  exit 1
}

check_no_invented_label "$agentgateway_dashboard_json" 'agentgateway_' 'Agentgateway' 'Agentgateway v1.6.0'

# The source of the metrics must exist in the repository, otherwise the panels
# stay empty: the custom field `api_key`, the scraped port and its network
# policy.
yq -o=json eval-all '[.]' "$agentgateway_app" >"$agentgateway_app_json"

jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "agentgateway-config")
  | .data["config.yaml"]' "$agentgateway_app_json" >"$agentgateway_config_yaml"

yq -e '.config.metrics.fields.add.api_key == "apiKey.name"' "$agentgateway_config_yaml" >/dev/null || {
  echo "the gateway configuration must declare the custom metric field api_key (apiKey.name): the dashboard labels are not invented" >&2
  exit 1
}

jq -e '[.[] | select(.kind == "Deployment" and .metadata.name == "agentgateway")
  | .spec.template.spec.containers[] | select(.name == "agentgateway")
  | .ports[] | select(.name == "stats") | .containerPort] == [15020]' "$agentgateway_app_json" >/dev/null || {
  echo "the agentgateway container must expose the named port stats on 15020 (STATS_ADDR default)" >&2
  exit 1
}

jq -e '[.[] | select(.kind == "CiliumNetworkPolicy" and .metadata.name == "agentgateway-private")
  | .spec.ingress[] | select(any(.toPorts[]?; any(.ports[]; .port == "15020")))
  | select(any(.fromEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "monitoring"))] | length == 1' \
  "$agentgateway_app_json" >/dev/null || {
  echo "the CiliumNetworkPolicy of the gateway must admit the namespace monitoring on 15020/TCP" >&2
  exit 1
}

yq -o=json eval-all '[select(.kind == "PodMonitor")]' "$agentgateway_scrape" >"$agentgateway_podmonitor_json"

jq -e '
  (length == 1) and
  (.[0].metadata.namespace == "monitoring") and
  (.[0].metadata.labels.release == "kube-prometheus-stack") and
  (.[0].spec.namespaceSelector.matchNames == ["agentgateway"]) and
  (.[0].spec.selector.matchLabels.app == "agentgateway") and
  ((.[0].spec.podMetricsEndpoints | length) == 1) and
  (.[0].spec.podMetricsEndpoints[0].port == "stats") and
  (.[0].spec.podMetricsEndpoints[0].scheme == "http") and
  (.[0].spec.podMetricsEndpoints[0].interval == "60s")
' "$agentgateway_podmonitor_json" >/dev/null || {
  echo "the PodMonitor of the gateway must scrape the port stats of the namespace agentgateway every 60 s" >&2
  exit 1
}

if rg -n -i 'nodes-aix|nodes-darwin|loki-dashboards|bloom-build|bloom-gateway|defaultDashboardsEnabled: true' \
  k8s/infrastructure/monitoring/prometheus-stack/grafana-catalog.yaml; then
  echo "disabled upstream catalogue leaked into curated catalogue" >&2
  exit 1
fi

echo "grafana dashboard contract: PASS ($total dashboards, stable UIDs, required folders and metadata)"
