#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/dr-synth-cleanup.sh"
fixture="$repo_root/tests/fixtures/dr-cleanup"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base_manifest="$fixture/manifest.json"

make_manifest() {
  local name="$1" filter="$2" out
  out="$tmp/$name.json"
  jq "$filter" "$base_manifest" >"$out"
  printf '%s' "$out"
}

run_cleanup() {
  local label="$1" manifest="$2" approval="${3:-}" fixture_case="${4:-}"
  local state="$tmp/state-$label" out="$tmp/out-$label"
  shift 4
  mkdir -p "$state" "$out"
  set +e
  env \
    DR_CLEANUP_FIXTURE_STATE="$state" \
    KUBECTL_BIN="$fixture/bin/kubectl" \
    DR_CLEANUP_JOURNAL="$out/journal.jsonl" \
    DR_CLEANUP_REPORT="$out/report.jsonl" \
    DR_CLEANUP_METADATA_DIR="$out/metadata" \
    DR_CLEANUP_TRANSITION_TIMEOUT=2 \
    DR_CLEANUP_POLL_SECONDS=0 \
    DR_CLEANUP_APPROVAL="$approval" \
    DR_CLEANUP_FIXTURE_CASE="$fixture_case" \
    "$script" "$@" --manifest "$manifest" >"$out/stdout" 2>"$out/stderr"
  rc=$?
  set -e
  printf '%s' "$rc"
}

approval_for() {
  local manifest="$1"
  printf 'APPROVE:dr-synth-test:%s:%s' \
    "$(sha256sum "$manifest" | awk '{print $1}')" \
    "$(sha256sum "$script" | awk '{print $1}')"
}

expect_nonzero() {
  local rc="$1" label="$2"
  (( rc != 0 )) || { echo "expected failure: $label" >&2; exit 1; }
}

manifest="$base_manifest"
sha="$(approval_for "$manifest")"
rc="$(run_cleanup dry-run "$manifest" "" "" --dry-run)"
[[ "$rc" == 0 ]]
grep -F 'DR_CLEANUP=DRY_RUN' "$tmp/out-dry-run/stdout" >/dev/null

rc="$(run_cleanup approval "$manifest" "" "" --apply)"
expect_nonzero "$rc" "approval gate"
grep -F 'approval token mismatch' "$tmp/out-approval/stderr" >/dev/null

rc="$(run_cleanup apply "$manifest" "$sha" "" --apply)"
[[ "$rc" == 0 ]]
grep -F 'DR_CLEANUP=PASS' "$tmp/out-apply/stdout" >/dev/null

rc="$(run_cleanup apply "$manifest" "$sha" "" --apply --resume)"
[[ "$rc" == 0 ]]
grep -F 'journal-confirmed' "$tmp/out-apply/report.jsonl" >/dev/null

wrong_uid="$(make_manifest wrong_uid '.namespaces[0].uid = "wrong-uid"')"
rc="$(run_cleanup wrong_uid "$wrong_uid" "" "" --dry-run)"
expect_nonzero "$rc" "wrong UID"
grep -F 'UID divergence' "$tmp/out-wrong_uid/stderr" >/dev/null

wrong_claim="$(make_manifest wrong_claim '.pvs[0].claimRef.name = "unexpected"')"
rc="$(run_cleanup wrong_claim "$wrong_claim" "" "" --dry-run)"
expect_nonzero "$rc" "unexpected claimRef"
grep -F 'PV claim name mismatch' "$tmp/out-wrong_claim/stderr" >/dev/null

recreated_state="$tmp/state-recreated"
recreated_out="$tmp/out-recreated"
mkdir -p "$recreated_state" "$recreated_out"
set +e
env DR_CLEANUP_FIXTURE_STATE="$recreated_state" KUBECTL_BIN="$fixture/bin/kubectl" \
  DR_CLEANUP_JOURNAL="$recreated_out/journal" DR_CLEANUP_REPORT="$recreated_out/report" \
  DR_CLEANUP_METADATA_DIR="$recreated_out/metadata" DR_CLEANUP_FIXTURE_CASE=namespace-recreated \
  "$script" --dry-run --manifest "$manifest" >"$recreated_out/stdout" 2>"$recreated_out/stderr"
rc=$?
set -e
expect_nonzero "$rc" "recreated namespace"
grep -F 'UID divergence' "$recreated_out/stderr" >/dev/null

rc="$(run_cleanup attached "$manifest" "" volume-attached --dry-run)"
[[ "$rc" == 0 ]]
rc="$(run_cleanup attached-apply "$manifest" "$sha" volume-attached --apply)"
expect_nonzero "$rc" "attached Longhorn volume deletion"
grep -F 'still has a VolumeAttachment' "$tmp/out-attached-apply/stderr" >/dev/null

rc="$(run_cleanup delayed "$manifest" "$sha" pv-delayed --apply)"
[[ "$rc" == 0 ]]

interrupt_state="$tmp/state-interrupt"
interrupt_out="$tmp/out-interrupt"
mkdir -p "$interrupt_state" "$interrupt_out"
set +e
env DR_CLEANUP_FIXTURE_STATE="$interrupt_state" KUBECTL_BIN="$fixture/bin/kubectl" \
  DR_CLEANUP_JOURNAL="$interrupt_out/journal.jsonl" DR_CLEANUP_REPORT="$interrupt_out/report.jsonl" \
  DR_CLEANUP_METADATA_DIR="$interrupt_out/metadata" DR_CLEANUP_FIXTURE_CASE=interrupt \
  DR_CLEANUP_APPROVAL="$sha" "$script" --apply --manifest "$manifest" >"$interrupt_out/stdout" 2>"$interrupt_out/stderr"
rc=$?
set -e
expect_nonzero "$rc" "interrupted deletion"
set +e
env DR_CLEANUP_FIXTURE_STATE="$interrupt_state" KUBECTL_BIN="$fixture/bin/kubectl" \
  DR_CLEANUP_JOURNAL="$interrupt_out/journal.jsonl" DR_CLEANUP_REPORT="$interrupt_out/report.jsonl" \
  DR_CLEANUP_METADATA_DIR="$interrupt_out/metadata" DR_CLEANUP_APPROVAL="$sha" \
  "$script" --apply --resume --manifest "$manifest" >"$interrupt_out/resume.stdout" 2>"$interrupt_out/resume.stderr"
rc=$?
set -e
expect_nonzero "$rc" "ambiguous absent resource on resume"
grep -F 'absent without matching journal deletion' "$interrupt_out/resume.stderr" >/dev/null

jq -cn '{ts:"test",run:"dr-synth-test",action:"deleted",kind:"namespace",namespace:"",name:"dr-synth-test-src",uid:"ns-src",detail:"independent-revalidation"}' >>"$interrupt_out/journal.jsonl"
rc="$(run_cleanup interrupt "$manifest" "$sha" "" --apply --resume)"
[[ "$rc" == 0 ]]

missing_proof="$(make_manifest missing_proof '.inventory.file = "/definitely/missing/inventory.md"')"
rc="$(run_cleanup missing_proof "$missing_proof" "" "" --dry-run)"
expect_nonzero "$rc" "missing proof"

bad_preserve="$(make_manifest bad_preserve '.preserve[0].uid = "wrong-backup-uid"')"
rc="$(run_cleanup bad_preserve "$bad_preserve" "" "" --dry-run)"
expect_nonzero "$rc" "preservation identity"
grep -F 'UID divergence' "$tmp/out-bad_preserve/stderr" >/dev/null

echo "dr-synth-cleanup safety contract: PASS"
