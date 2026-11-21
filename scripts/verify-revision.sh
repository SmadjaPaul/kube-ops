#!/usr/bin/env bash
# RECONCILED proof (PLT-390 lot 3): the Argo CD Application is Synced + Healthy at a given Git revision.
# Reads status.sync.revision / status.operationState of the Application through scripts/kubectl-ro.sh
# (read-only, agent identity). Complements scripts/verify-delivery.sh, whose Grafana metric has no revision.
#
# Usage: bash scripts/verify-revision.sh ARGO_APP SHA [--cluster homelab|oracle-a1] [--timeout SEC<=600] [--interval SEC] [--exact] [--allow-unhealthy] [--deadline EPOCH]
#   ARGO_APP  Argo Application name (e.g. app-bookorbit, or apps-platform: one Application per domain directory)
#   SHA       merge commit, 7-40 hex chars
#   --exact   the Application revision must equal SHA. Default: SHA or any commit that contains it
#             (main moved on). A revision missing from the local clone is fetched (`git fetch origin`, PLT-398).
#   --deadline EPOCH  absolute end of the wait (unix seconds), shared by several calls: the wait ends at the
#             earlier of now+--timeout and EPOCH. At least one check is always made.
#   --allow-unhealthy  still waits for Healthy until --timeout, but at the deadline a Synced Application whose
#             last operation Succeeded at the revision is PASS (REVISION=PROVEN, HEALTH=<status> printed). Health is
#             aggregate over the domain Application, so it must not gate the revision proof; the per-app verdict
#             belongs to app-test. A sync failure or a revision never reached stays FAIL.
# Exit: 0 PASS, 1 FAIL (timeout or wrong state), 2 BLOCKED (usage, no cluster access, bad JSON).
# Test seam: KUBECTL_RO_BIN replaces scripts/kubectl-ro.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: verify-revision.sh ARGO_APP SHA [--cluster homelab|oracle-a1] [--timeout SEC<=600] [--interval SEC] [--exact] [--allow-unhealthy] [--deadline EPOCH]" >&2; exit 2; }
blocked() { echo "REVISION=NOT_PROVEN"; echo "LAST_ERROR=$1"; echo "VERIFY_REVISION=BLOCKED"; exit 2; }

[[ $# -ge 2 ]] || usage
app=$1; sha=$2; shift 2
cluster=homelab; timeout=600; interval=15; exact=0; allow_unhealthy=0; abs_deadline=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) cluster=${2:?}; shift 2 ;;
    --timeout) timeout=${2:?}; shift 2 ;;
    --interval) interval=${2:?}; shift 2 ;;
    --exact) exact=1; shift ;;
    --allow-unhealthy) allow_unhealthy=1; shift ;;
    --deadline) abs_deadline=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
case "$cluster" in homelab|oracle-a1) ;; *) usage ;; esac
[[ $app =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || usage
[[ $sha =~ ^[0-9a-f]{7,40}$ ]] || usage
[[ $timeout =~ ^[0-9]+$ && $interval =~ ^[0-9]+$ ]] || usage
[[ -z $abs_deadline || $abs_deadline =~ ^[0-9]+$ ]] || usage
(( timeout <= 600 )) || { echo "ERROR: --timeout is capped at 600 s" >&2; exit 2; }
command -v jq >/dev/null || blocked "jq required"

ro() {
  if [[ -n ${KUBECTL_RO_BIN:-} ]]; then "$KUBECTL_RO_BIN" "$@"; else bash "$here/kubectl-ro.sh" "$@"; fi
}

have_commit() { git -C "$here/.." cat-file -e "$1^{commit}" 2>/dev/null; }
fetch_round=0
fetch_missing() { # main moves on during the wait (Renovate bursts): the checkout may lack the commit (PLT-398)
  git -C "$here/.." rev-parse --git-dir >/dev/null 2>&1 || return 0
  GIT_TERMINAL_PROMPT=0 git -C "$here/.." fetch --quiet --no-tags origin >/dev/null 2>&1 || true
}
contains_sha() { # REV: equals SHA (prefix) or descends from it
  local rev=$1
  [[ -n $rev ]] || return 1
  [[ $rev == "$sha"* || $sha == "$rev"* ]] && return 0
  (( exact == 1 )) && return 1
  if ! have_commit "$sha" || ! have_commit "$rev"; then
    (( fetch_round == 1 )) || { fetch_missing; fetch_round=1; }
  fi
  have_commit "$sha" && have_commit "$rev" && git -C "$here/.." merge-base --is-ancestor "$sha" "$rev" 2>/dev/null
}

err=$(mktemp "${TMPDIR:-/tmp}/verify-revision.XXXXXX"); trap 'rm -f "$err"' EXIT
sync=none; health=none; phase=none; rev_seen=none; match=no; reason=none; verdict=FAIL; soft_ok=no

check_once() {
  fetch_round=0; verdict=FAIL; reason=none; match=no; soft_ok=no
  local json rc=0
  json=$(ro --cluster "$cluster" get application "$app" -n argocd -o json 2>"$err") || rc=$?
  if (( rc != 0 )); then
    if grep -q 'NotFound' "$err"; then reason="Application $app not found"; return; fi
    blocked "cluster read failed (exit $rc): $(tr '\n' ' ' <"$err" | cut -c1-200)"
  fi
  jq -e '.status' >/dev/null 2>&1 <<<"$json" || { reason="Application has no status yet"; return; }
  sync=$(jq -r '.status.sync.status // "none"' <<<"$json")
  health=$(jq -r '.status.health.status // "none"' <<<"$json")
  phase=$(jq -r '.status.operationState.phase // "none"' <<<"$json")
  rev_seen=$(jq -r '[.status.sync.revision // empty, (.status.sync.revisions // [])[]] | unique | join(",") | if .=="" then "none" else . end' <<<"$json")
  local r
  while IFS= read -r r; do [[ -z $r ]] || { contains_sha "$r" && match=yes; }; done \
    < <(jq -r '[.status.sync.revision // empty, (.status.sync.revisions // [])[]] | unique | .[]' <<<"$json")
  if [[ $match != yes ]]; then reason="revision $rev_seen does not contain $sha"; return; fi
  if [[ $sync != Synced ]]; then reason="Argo sync $sync at the target revision"; return; fi
  case "$phase" in Running|Failed|Error|Terminating) reason="last operation $phase"; return ;; esac
  if [[ $health != Healthy ]]; then soft_ok=yes; reason="Argo health $health at the target revision"; return; fi
  verdict=PASS
}

deadline=$(( $(date +%s) + timeout ))
[[ -z $abs_deadline ]] || (( abs_deadline >= deadline )) || deadline=$abs_deadline
while :; do
  check_once
  [[ $verdict == PASS ]] && break
  (( $(date +%s) + interval > deadline )) && break
  sleep "$interval"
done

if [[ $verdict != PASS && $allow_unhealthy == 1 && $soft_ok == yes ]]; then verdict=PASS; fi

echo "CLUSTER=$cluster"
echo "ARGO_APP=$app"
echo "WANT_REVISION=$sha"
echo "SYNC_REVISION=$rev_seen"
echo "ARGO=$sync/$health"
echo "HEALTH=$health"
echo "OPERATION=$phase"
echo "EVIDENCE_LEVEL=RECONCILED"
if [[ $verdict == PASS ]]; then echo "REVISION=PROVEN"; else echo "REVISION=NOT_PROVEN"; fi
echo "LAST_ERROR=$reason"
echo "VERIFY_REVISION=$verdict"
[[ $verdict == PASS ]]
