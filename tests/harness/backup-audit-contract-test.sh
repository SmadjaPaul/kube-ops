#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/backup-audit"
output="$(mktemp)"
positive_dir="$(mktemp -d)"
negative_dir="$(mktemp -d)"
cnpg_negative_dir="$(mktemp -d)"
longhorn_dir="$(mktemp -d)"
stale_evidence_dir="$(mktemp -d)"
tmp_json="$longhorn_dir/mutation.tmp.json"
trap 'rm -f "$output"; rm -rf "$positive_dir" "$negative_dir" "$cnpg_negative_dir" "$longhorn_dir" "$stale_evidence_dir"' EXIT

cp -R "$fixture_dir/." "$positive_dir/"
BACKUP_AUDIT_INPUT_DIR="$positive_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output"
test ! -e "$fixture_dir/report.json"
test ! -e "$positive_dir/report.json"

grep -F 'PRODUCTION_PVC_COVERAGE=PASS (1/1)' "$output" >/dev/null
grep -F 'CNPG_BACKUP_CONFIGURATION=PASS (1/1)' "$output" >/dev/null
grep -F 'CNPG_RESTORE_PROOF=UNPROVEN' "$output" >/dev/null
grep -F 'RESTORE_DRILL_SUCCESS=FAIL' "$output" >/dev/null
grep -F 'RESTORE_RESIDUE_COUNT=2' "$output" >/dev/null
grep -F 'ORPHAN_PVC_COUNT=1' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_GAPS=2' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_LEGACY_GAPS=2' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_UNVERIFIED=0' "$output" >/dev/null

cp -R "$fixture_dir/." "$longhorn_dir/"
jq '.items=[]' "$longhorn_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/pvbs.json"
jq '.items=[{"metadata":{"name":"pv-invoice-storage"},"status":{"kubernetesStatus":{"namespace":"invoice-ninja","pvcName":"storage"}}}]' \
  "$longhorn_dir/longhorn-volumes.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-volumes.json"
jq '.items=[{"metadata":{"name":"backup-invoice-storage"},"status":{"state":"Completed","volumeName":"pv-invoice-storage"}}]' \
  "$longhorn_dir/longhorn-backups.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-backups.json"
jq '.items=[
  {"kind":"Velero/Kopia","status":"PASS","accepted":true},
  {"kind":"CNPG/Barman","status":"PASS","accepted":true}
]' "$longhorn_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/restore-evidence.json"
longhorn_report="$longhorn_dir/report.json"
BACKUP_AUDIT_INPUT_DIR="$longhorn_dir" BACKUP_AUDIT_REPORT_FILE="$longhorn_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
grep -F 'PRODUCTION_PVC_COVERAGE=PASS (1/1)' "$output" >/dev/null
grep -F 'CNPG_RESTORE_PROOF=PASS' "$output" >/dev/null
grep -F 'RESTORE_DRILL_SUCCESS=PASS' "$output" >/dev/null
jq -e '.productionPVCs[0].backupMechanism == "longhorn-s3" and .productionPVCs[0].offsiteBackupVerified == true' \
  "$longhorn_report" >/dev/null

cp -R "$fixture_dir/." "$stale_evidence_dir/"
jq '.producedAt="2020-01-01T00:00:00Z"' "$stale_evidence_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$stale_evidence_dir/restore-evidence.json"
BACKUP_AUDIT_INPUT_DIR="$stale_evidence_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output"
grep -F 'CNPG_RESTORE_PROOF=UNPROVEN' "$output" >/dev/null
grep -F 'RESTORE_DRILL_SUCCESS=FAIL' "$output" >/dev/null

cp -R "$fixture_dir/." "$negative_dir/"
tmp_json="$negative_dir/pvbs.tmp.json"
jq '.items=[]' "$negative_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$negative_dir/pvbs.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$negative_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output" 2>&1
missing_pvb_rc=$?
set -e
(( missing_pvb_rc != 0 ))
grep -F 'PRODUCTION_PVC_COVERAGE=UNKNOWN' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_UNVERIFIED=1' "$output" >/dev/null

cp -R "$fixture_dir/." "$cnpg_negative_dir/"
jq '.items[0].status.phase="Failed"' "$cnpg_negative_dir/cnpg-backups.json" >"$tmp_json"
mv "$tmp_json" "$cnpg_negative_dir/cnpg-backups.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$cnpg_negative_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output" 2>&1
failed_cnpg_rc=$?
set -e
(( failed_cnpg_rc != 0 ))
grep -F 'CNPG_BACKUP_CONFIGURATION=FAIL' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_LEGACY_GAPS=3' "$output" >/dev/null

echo "backup-audit contract: PASS"
