#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/backup-audit"
output="$(mktemp)"
positive_dir="$(mktemp -d)"
negative_dir="$(mktemp -d)"
cnpg_negative_dir="$(mktemp -d)"
trap 'rm -f "$output"; rm -rf "$positive_dir" "$negative_dir" "$cnpg_negative_dir"' EXIT

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
