#!/usr/bin/env bash
# PLT-506: the Alloy counter and the VeleroBackupSkippedVolumes alert stay wired.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { echo "VELERO_SKIPPED_VOLUMES_ALERT=FAIL: $*" >&2; exit 1; }

alloy="$ROOT/k8s/infrastructure/monitoring/alloy/values.yaml"
rules="$ROOT/k8s/infrastructure/controllers/velero/prometheusrule.yaml"
rule='select(.metadata.name == "velero-backup-volume-alerts")'

[ "$(yq -r "$rule | .metadata.labels.release" "$rules")" = kube-prometheus-stack ] ||
  fail "label release absent : Prometheus ne chargerait pas la règle"
yq -r "$rule | .spec.groups[].rules[].expr" "$rules" |
  grep -qF 'loki_process_custom_velero_skipped_pod_volumes_total{velero_schedule!=""}' ||
  fail "expression sans le compteur Alloy"
grep -qxF '### VeleroBackupSkippedVolumes' "$ROOT/docs/operations/alert-runbooks.md" ||
  fail "entrée de runbook absente"

# Replay Velero 1.18.2 log lines (shortened) against the filters of the pipeline.
yq -r '.alloy.configMap.content' "$alloy" | python3 -I -c '
import re, sys
cfg = sys.stdin.read()
block = cfg[cfg.index("// PLT-506"):]
block = block[:block.index("stage.static_labels")]
selector = re.search(r"selector = `([^`]*)`", block).group(1)
contains = re.search(r"\|= \"((?:\\.|[^\"\\])*)\"", selector).group(1).replace("\\\"", "\"")
phase = re.search(r"\|~ \"([^\"]*)\"", selector).group(1)
schedule = re.compile(re.search(r"expression = `([^`]*)`", block).group(1))
assert "name        = \"velero_skipped_pod_volumes_total\"" in block
assert "max_idle_duration = \"25h\"" in block

def line(backup, ph):
    return ("time=\"2026-11-25T09:19:34Z\" level=warning msg=\"Skip pod volume data\" backup=velero/" + backup
            + " error=\"pod is not in the expected status, name=p-0, namespace=n, phase=" + ph
            + ": pod is not running\" resource=pods")

def counted(text):
    if contains not in text or not re.search(phase, text):
        return None
    return schedule.search(text).group("velero_schedule")

for name in ("velero-daily-home-assistant", "velero-daily-qbittorrent-mam"):
    for ph in ("Pending", "Unknown"):
        assert counted(line(name + "-20261125091914", ph)) == name, (name, ph)
for ph in ("Succeeded", "Failed"):
    assert counted(line("velero-daily-immich-20261123020002", ph)) is None, ph
assert counted("level=info msg=\"Skipping item because it has already been backed up.\"") is None
' || fail "filtre Alloy"

echo 'VELERO_SKIPPED_VOLUMES_ALERT=PASS'
