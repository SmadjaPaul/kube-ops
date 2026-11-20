#!/usr/bin/env bash
# Single entry point for a live-cluster investigation (read-only, through kubectl-ro.sh).
#
# Usage: bash scripts/investigate.sh app <name> [--cluster homelab|oracle-a1] [summary|errors|full]
#   OUTPUT=summary|errors|full also selects the mode (default summary).
#
# Sections, one call:
#   === ARGO ===       scripts/status-app.sh   (sync, health, revision, last error)
#   === WORKLOADS ===  scripts/diagnose-app.sh (pods Ready, warning events)
#   === METRICS ===    scripts/observe.sh app  (Grafana Cloud; UNAVAILABLE is not a failure)
# Contract: VERIFY=PASS only when Argo is Synced/Healthy and every pod is Ready with no
# warning event; metrics never change the verdict. EVIDENCE=<private 0600 file> holds the
# sections. EVIDENCE_SCOPE=RUNTIME: it proves neither Git reconciliation nor a user path.
# Exit: 0 PASS, 1 FAIL, 2 usage or cluster access/lookup error (stderr says which).
# status-app.sh and diagnose-app.sh stay internal modules (also reachable by just recipe).
# KUBECTL_RO_SCRIPT / OBSERVE_SCRIPT override the wrappers (offline tests with fakes only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output-mode.sh
source "$HERE/lib/output-mode.sh"

usage() { echo "usage: investigate.sh app <name> [--cluster homelab|oracle-a1] [summary|errors|full]" >&2; exit 2; }
[[ "${1:-}" == app && -n "${2:-}" ]] || usage
app=$2
shift 2
cluster=homelab
cluster_given=0
mode_arg=""
while (($#)); do
  case "$1" in
    --cluster)
      [[ -n "${2:-}" ]] || usage
      case "$2" in homelab|oracle-a1) cluster=$2; cluster_given=1 ;; *) echo "ERROR: cluster must be homelab|oracle-a1" >&2; exit 2 ;; esac
      shift 2 ;;
    summary|errors|full) mode_arg=$1; shift ;;
    *) usage ;;
  esac
done
[[ "$app" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "ERROR: app name must be a DNS label" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }
mode="$(resolve_output_mode "${mode_arg:-${OUTPUT:-summary}}")"
[[ "$cluster_given" == 0 ]] || export KUBECTL_RO_CLUSTER="$cluster"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/investigate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
evidence="$(evidence_file "investigate-$app")"

# Verdict inputs: both modules in summary mode (stdout captured, stderr passes through).
argo_rc=0 work_rc=0
bash "$HERE/status-app.sh" "$app" summary >"$tmp/argo.out" || argo_rc=$?
if ((argo_rc != 0)); then
  echo "ERROR: status-app failed (exit $argo_rc): Application lookup or cluster access" >&2
  exit 2
fi
bash "$HERE/diagnose-app.sh" "$app" summary >"$tmp/work.out" || work_rc=$?
if ((work_rc != 0)); then
  echo "ERROR: diagnose-app failed (exit $work_rc): cluster access" >&2
  exit 2
fi

# Metrics: optional. Grafana covers both clusters; the label `cluster` tells them apart.
metrics_name="${app#apps-}"; metrics_name="${metrics_name#infra-}"
if bash "${OBSERVE_SCRIPT:-$HERE/observe.sh}" app "$metrics_name" >"$tmp/metrics.out" 2>"$tmp/metrics.err"; then
  :
else
  reason="$(head -1 "$tmp/metrics.err" | sanitize_line)"
  { echo "METRICS=UNAVAILABLE (${reason:-observe.sh failed})"; cat "$tmp/metrics.out"; } >"$tmp/metrics.tmp"
  mv "$tmp/metrics.tmp" "$tmp/metrics.out"
fi

verdict_of() { sed -n 's/^VERIFY=//p' "$1" | tail -1; }
body_of() { grep -Ev '^(VERIFY|EVIDENCE)=' "$1" || true; }
argo_verify="$(verdict_of "$tmp/argo.out")"
work_verify="$(verdict_of "$tmp/work.out")"
verify=FAIL
[[ "$argo_verify" == PASS && "$work_verify" == PASS ]] && verify=PASS

{
  echo "APP=$app"
  echo "CLUSTER=$cluster"
  echo "=== ARGO ==="
  body_of "$tmp/argo.out"
  echo "ARGO_VERIFY=${argo_verify:-FAIL}"
  echo "=== WORKLOADS ==="
  body_of "$tmp/work.out" | grep -Ev '^(ARGO|REVISION)=' || true
  echo "WORKLOADS_VERIFY=${work_verify:-FAIL}"
  echo "=== METRICS ==="
  cat "$tmp/metrics.out"
} >"$tmp/report.out"

if [[ "$mode" != summary ]]; then
  {
    echo "=== DETAIL ARGO ($mode) ==="
    bash "$HERE/status-app.sh" "$app" "$mode"
    echo "=== DETAIL WORKLOADS ($mode) ==="
    bash "$HERE/diagnose-app.sh" "$app" "$mode"
  } >>"$tmp/report.out"
fi

cp "$tmp/report.out" "$evidence"
cat "$tmp/report.out"
echo "EVIDENCE_SCOPE=RUNTIME"
echo "VERIFY=$verify"
echo "EVIDENCE=$evidence"
[[ "$verify" == PASS ]]
