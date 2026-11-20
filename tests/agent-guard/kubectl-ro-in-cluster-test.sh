#!/usr/bin/env bash
# Mode in-cluster de scripts/kubectl-ro.sh (PLT-390 lot 3) et lecture ntfy de post-merge-notify.sh.
# Faux kubectl/curl, faux jeton ServiceAccount : aucun cluster, aucun Doppler.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kubectl-ro-incluster.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok() { echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
mkdir -p "$WORK/bin" "$WORK/sa"
echo faketoken >"$WORK/sa/token"
# Fausse préflight qui échoue si elle est appelée : le mode in-cluster ne doit jamais toucher Doppler.
mkdir -p "$WORK/scripts/lib"
cp "$ROOT/scripts/kubectl-ro.sh" "$WORK/scripts/"
cat >"$WORK/scripts/lib/kube-preflight.sh" <<'SH'
_kube_access_sha256_stream() { shasum -a 256 | cut -d' ' -f1; }
kube_access_cleanup() { :; }
require_kube_access() { echo "PREFLIGHT_CALLED" >>"$WORK_LOG"; return 2; }
SH
cat >"$WORK/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "kubectl KUBECONFIG=${KUBECONFIG:-unset} $*" >>"$WORK_LOG"
case "$*" in
  *"auth whoami"*) printf '%s' "${FAKE_WHO:-system:serviceaccount:arc-runners-kube-ops:kube-ops-post-merge}" ;;
  *"get secret alertmanager-ntfy-url"*) printf '%s' "$(printf 'https://ntfy.example/secret-topic-123' | base64)" ;;
  *) echo "KUBECTL_OK $*" ;;
esac
SH
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
cat >"$WORK_CURL_STDIN"; echo "curl-args: $*" >>"$WORK_LOG"
SH
chmod +x "$WORK/bin/kubectl" "$WORK/bin/curl"
export WORK_LOG="$WORK/log" WORK_CURL_STDIN="$WORK/curl-stdin"; : >"$WORK_LOG"
run() { env PATH="$WORK/bin:$PATH" KUBECONFIG=/ambient/kubeconfig KUBECTL_RO_IN_CLUSTER=1 KUBECTL_RO_SA_DIR="$WORK/sa" "$@" ; }

out=$(run bash "$WORK/scripts/kubectl-ro.sh" get pods -n media 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"get pods -n media"* ]] && ok "in-cluster get passes" || ko "in-cluster get (rc=$rc): $out"
grep -q PREFLIGHT_CALLED "$WORK_LOG" && ko "preflight/Doppler called in in-cluster mode" || ok "no Doppler preflight"
grep -q 'KUBECONFIG=/ambient' "$WORK_LOG" && ko "ambient KUBECONFIG leaked" || ok "ambient KUBECONFIG unset"
out=$(FAKE_WHO=system:serviceaccount:agent-operator:agent-operator run bash "$WORK/scripts/kubectl-ro.sh" get pods 2>&1); rc=$?
[[ $rc -ne 0 && $out == *"seule system:serviceaccount:arc-runners-kube-ops:kube-ops-post-merge"* ]] && ok "other identity refused" || ko "other identity accepted (rc=$rc)"
out=$(run bash "$WORK/scripts/kubectl-ro.sh" get secret x -o yaml 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "Secret content still refused" || ko "secret -o yaml accepted"
out=$(env PATH="$WORK/bin:$PATH" KUBECTL_RO_IN_CLUSTER=1 KUBECTL_RO_SA_DIR="$WORK/nosa" bash "$WORK/scripts/kubectl-ro.sh" get pods 2>&1); rc=$?
[[ $rc -ne 0 && $out == *"hors pod"* ]] && ok "outside a pod: refused, no fallback" || ko "no token accepted (rc=$rc)"
out=$(run bash "$WORK/scripts/kubectl-ro.sh" --cluster oracle-a1 get pods 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "oracle-a1 refused in-cluster" || ko "oracle-a1 accepted"

# ntfy: URL read from the Secret, passed by curl config on stdin, never printed or in arguments.
: >"$WORK_LOG"
out=$(run bash "$ROOT/scripts/post-merge-notify.sh" "t" high "m" 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"NOTIFY=SENT"* ]] && ok "notify sent" || ko "notify (rc=$rc): $out"
[[ $out != *secret-topic-123* ]] && ok "URL not printed" || ko "URL printed"
grep -q 'secret-topic-123' "$WORK_LOG" && ko "URL in arguments/log" || ok "URL not in arguments"
grep -q 'secret-topic-123' "$WORK_CURL_STDIN" && ok "URL given on stdin" || ko "URL missing from curl stdin"
echo "kubectl-ro in-cluster test: $([[ $FAIL -eq 0 ]] && echo PASS || echo "FAIL ($FAIL)")"
exit "$FAIL"
