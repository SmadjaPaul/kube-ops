#!/usr/bin/env bash
# Contract test of scripts/verify-revision.sh with a fake kubectl-ro (no cluster, no network).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-revision-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567

# Fake kubectl-ro: prints $FX_APP, or fails like the real wrapper according to $FX_MODE.
cat >"$tmp/kro" <<'SH'
#!/usr/bin/env bash
case "${FX_MODE:-ok}" in
  notfound) echo 'Error from server (NotFound): applications.argoproj.io "x" not found' >&2; exit 1 ;;
  noaccess) echo 'KUBE_ACCESS=BLOCKED' >&2; exit 2 ;;
  seq) n=$(cat "$FX_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) >"$FX_DIR/n"; cat "$FX_DIR/step.$((n % $(ls "$FX_DIR"/step.* | wc -l)))" ;;
  *) cat "$FX_FILE" ;;
esac
SH
chmod +x "$tmp/kro"

app_json() { # sync health phase revision
  printf '{"status":{"sync":{"status":"%s","revision":"%s"},"health":{"status":"%s"},"operationState":{"phase":"%s"}}}' "$1" "$4" "$2" "$3"
}
run() { # want_exit args...
  local want=$1; shift; set +e
  out=$(KUBECTL_RO_BIN="$tmp/kro" FX_FILE="$tmp/app.json" FX_MODE="${FX_MODE:-ok}" FX_DIR="$tmp" bash "$repo_root/scripts/verify-revision.sh" "$@" 2>&1); got=$?
  set -e
  [[ $got -eq $want ]] || { echo "FAIL: exit $got, want $want for: $*"; echo "$out"; exit 1; }
}
expect() { [[ $out == *"$1"* ]] || { echo "FAIL: output lacks '$1'"; echo "$out"; exit 1; }; }

app_json Synced Healthy Succeeded "$SHA" >"$tmp/app.json"
run 0 apps-media "$SHA" --timeout 0;  expect "VERIFY_REVISION=PASS"; expect "REVISION=PROVEN"; expect "EVIDENCE_LEVEL=RECONCILED"
run 0 apps-media "${SHA:0:12}" --timeout 0 --exact; expect "VERIFY_REVISION=PASS"   # short SHA accepted

app_json Synced Healthy Succeeded "fedcba9876543210fedcba9876543210fedcba98" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0;  expect "REVISION=NOT_PROVEN"; expect "does not contain"
# Revision is a descendant of the merge commit: proven (real git history in a throwaway repo).
g="$tmp/repo"; mkdir -p "$g/scripts"; git -C "$g" init -q; cp "$repo_root/scripts/verify-revision.sh" "$g/scripts/"
git -C "$g" -c user.email=t@t -c user.name=t commit -q --allow-empty -m a; a=$(git -C "$g" rev-parse HEAD)
git -C "$g" -c user.email=t@t -c user.name=t commit -q --allow-empty -m b; b=$(git -C "$g" rev-parse HEAD)
app_json Synced Healthy Succeeded "$b" >"$tmp/app.json"
set +e; out=$(KUBECTL_RO_BIN="$tmp/kro" FX_FILE="$tmp/app.json" bash "$g/scripts/verify-revision.sh" apps-media "$a" --timeout 0 2>&1); got=$?; set -e
[[ $got -eq 0 && $out == *"VERIFY_REVISION=PASS"* ]] || { echo "FAIL: descendant revision not proven"; echo "$out"; exit 1; }
set +e; out=$(KUBECTL_RO_BIN="$tmp/kro" FX_FILE="$tmp/app.json" bash "$g/scripts/verify-revision.sh" apps-media "$a" --timeout 0 --exact 2>&1); got=$?; set -e
[[ $got -eq 1 ]] || { echo "FAIL: --exact accepted a descendant"; exit 1; }

app_json OutOfSync Healthy Succeeded "$SHA" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0;  expect "sync OutOfSync"
app_json Synced Progressing Succeeded "$SHA" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0;  expect "health Progressing"
app_json Synced Healthy Failed "$SHA" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0;  expect "last operation Failed"
# --allow-unhealthy: health does not gate the revision proof, the sync and the operation do.
app_json Synced Degraded Succeeded "$SHA" >"$tmp/app.json"
run 0 apps-media "$SHA" --timeout 0 --allow-unhealthy; expect "VERIFY_REVISION=PASS"; expect "REVISION=PROVEN"; expect "HEALTH=Degraded"
run 1 apps-media "$SHA" --timeout 0; expect "REVISION=NOT_PROVEN"; expect "HEALTH=Degraded"
app_json Synced Degraded Failed "$SHA" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0 --allow-unhealthy; expect "last operation Failed"
app_json OutOfSync Degraded Succeeded "$SHA" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0 --allow-unhealthy; expect "sync OutOfSync"
app_json Synced Degraded Succeeded "fedcba9876543210fedcba9876543210fedcba98" >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0 --allow-unhealthy; expect "does not contain"
# Waits for Healthy first: Progressing then Healthy -> PASS with HEALTH=Healthy; never Healthy -> PASS at the deadline.
rm -rf "$tmp/n"; app_json Synced Progressing Succeeded "$SHA" >"$tmp/step.0"; app_json Synced Healthy Succeeded "$SHA" >"$tmp/step.1"
FX_MODE=seq run 0 apps-media "$SHA" --timeout 5 --interval 0 --allow-unhealthy; expect "HEALTH=Healthy"
rm -f "$tmp/n" "$tmp/step.1"
FX_MODE=seq run 0 apps-media "$SHA" --timeout 1 --interval 0 --allow-unhealthy; expect "HEALTH=Progressing"; expect "REVISION=PROVEN"
rm -f "$tmp/n" "$tmp/step.0"
echo '{"metadata":{}}' >"$tmp/app.json"
run 1 apps-media "$SHA" --timeout 0;  expect "no status"
FX_MODE=notfound run 1 apps-media "$SHA" --timeout 0; expect "not found"
FX_MODE=noaccess run 2 apps-media "$SHA" --timeout 0; expect "VERIFY_REVISION=BLOCKED"; expect "REVISION=NOT_PROVEN"

# Polling: Progressing, then Healthy at the revision -> PASS on the second poll; never Healthy -> FAIL at timeout.
rm -rf "$tmp/n"; app_json Synced Progressing Succeeded "$SHA" >"$tmp/step.0"; app_json Synced Healthy Succeeded "$SHA" >"$tmp/step.1"
FX_MODE=seq run 0 apps-media "$SHA" --timeout 5 --interval 0; expect "VERIFY_REVISION=PASS"
rm -f "$tmp/n" "$tmp/step.1"
FX_MODE=seq run 1 apps-media "$SHA" --timeout 1 --interval 0; expect "VERIFY_REVISION=FAIL"

run 2 apps-media "$SHA" --timeout 601
run 2 'bad;name' "$SHA"
run 2 apps-media 'not-a-sha'
run 2 apps-media
echo "verify-revision contract test: PASS"
