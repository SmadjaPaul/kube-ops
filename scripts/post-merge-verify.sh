#!/usr/bin/env bash
# Post-merge verification and revert decision (PLT-390 lot 3).
# Per merge commit: apps touched -> Argo Synced+Healthy at the commit (RECONCILED) -> `just app-test APP NS
# --phase runtime --cluster homelab` (RUNTIME) -> decision (scripts/lib/post-merge-decision.sh).
# This script needs read access to the cluster (kubectl-ro) and decides; the revert PR itself is opened by
# scripts/post-merge-revert.sh with the bot identity, in another job (the cluster runner never holds that key).
#
# Usage: bash scripts/post-merge-verify.sh [--dry-run] [--cluster homelab] [--timeout SEC<=600] [SHA]
#   --dry-run  read-only checks still run; prints the decision and the revert plan, creates no PR, sends no ntfy.
# Output: per-app CHECK lines, DECISION=NONE|NOTIFY|REVERT|ESCALATE, REASON=.., then POST_MERGE=PASS|FAIL|BLOCKED.
# Exit: 0 nothing to revert (PASS or notified), 1 REVERT or ESCALATE needed, 2 BLOCKED (usage).
# Writes decision/reason/stateful/sha to $GITHUB_OUTPUT when set.
# Test seams: JUST_BIN, GH_BIN, VERIFY_REVISION_BIN, PM_MAIN_REF (default origin/main).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/.." || exit 2
# shellcheck source=lib/post-merge-decision.sh
source scripts/lib/post-merge-decision.sh

dry=0; cluster=homelab; timeout=600; sha=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --cluster) cluster=${2:?}; shift 2 ;;
    --timeout) timeout=${2:?}; shift 2 ;;
    -*) echo "usage: post-merge-verify.sh [--dry-run] [--cluster homelab] [--timeout SEC] [SHA]" >&2; exit 2 ;;
    *) sha=$1; shift ;;
  esac
done
sha=$(git rev-parse --verify "${sha:-HEAD}^{commit}" 2>/dev/null) || { echo "ERROR: unknown commit" >&2; exit 2; }
JUST=${JUST_BIN:-just}; GH=${GH_BIN:-gh}; main_ref=${PM_MAIN_REF:-origin/main}
VREV=${VERIFY_REVISION_BIN:-bash scripts/verify-revision.sh}

echo "COMMIT=$sha"
echo "SUBJECT=$(git log -1 --format=%s "$sha")"
aff=$(bash scripts/post-merge-affected.sh "$sha") || { echo "ERROR: affected-apps mapping failed" >&2; exit 2; }
printf '%s\n' "$aff"
PM_CLASS=$(sed -n 's/^AFFECTED_CLASS=//p' <<<"$aff")
mapfile -t app_lines < <(grep '^AFFECTED_APP ' <<<"$aff")

# --- facts for the guards
subject=$(git log -1 --format=%s "$sha"); body=$(git log -1 --format=%B "$sha")
PM_IS_REVERT=no
re_revert='^[Rr]evert(\(.*\))?(: | ")'
if [[ $subject =~ $re_revert ]] || grep -q '^Post-merge-revert-of: ' <<<"$body"; then PM_IS_REVERT=yes; fi
if [[ $PM_IS_REVERT == no ]] && "$GH" api "repos/{owner}/{repo}/commits/$sha/pulls" --jq '.[].labels[].name' 2>/dev/null | grep -qx 'post-merge-revert'; then PM_IS_REVERT=yes; fi

PM_REVERT_ATTEMPTED=no
branch=claude/post-merge-revert-${sha:0:12}
if git log "$main_ref" --grep="Post-merge-revert-of: $sha" --format=%H -n1 2>/dev/null | grep -q . \
  || [[ -n $("$GH" pr list --state all --head "$branch" --json number --jq '.[].number' 2>/dev/null) ]]; then PM_REVERT_ATTEMPTED=yes; fi

PM_NEWER_COMMIT=no; PM_STATEFUL=no
dirs=()
for l in "${app_lines[@]:-}"; do
  [[ -n $l ]] || continue
  app=$(sed -n 's/.* name=\([^ ]*\).*/\1/p' <<<"$l")
  [[ $l == *"stateful=yes"* ]] && PM_STATEFUL=yes
  d=$(find k8s/applications -mindepth 2 -maxdepth 3 -type d -name "$app" 2>/dev/null | head -1)
  [[ -n $d ]] && dirs+=("$d")
done
if (( ${#dirs[@]} )) && git rev-parse --verify "$main_ref" >/dev/null 2>&1 \
  && [[ -n $(git log "$sha..$main_ref" --format=%H -n1 -- "${dirs[@]}") ]]; then PM_NEWER_COMMIT=yes; fi

# --- checks per app
PM_REVISION=PROVEN; PM_APP_TEST=PASS; any_fail=0; any_block=0
deploy_fail=0; deploy_unknown=0; failed_ids=""
for l in "${app_lines[@]:-}"; do
  [[ -n $l ]] || continue
  app=$(sed -n 's/.* name=\([^ ]*\).*/\1/p' <<<"$l"); ns=$(sed -n 's/.* namespace=\([^ ]*\).*/\1/p' <<<"$l"); argo=$(sed -n 's/.* argo=\([^ ]*\).*/\1/p' <<<"$l")
  # shellcheck disable=SC2086
  rev_out=$($VREV "$argo" "$sha" --cluster "$cluster" --timeout "$timeout" --allow-unhealthy 2>&1); rev_rc=$?
  echo "CHECK revision app=$app argo=$argo $(grep -E '^(ARGO|HEALTH|REVISION|LAST_ERROR)=' <<<"$rev_out" | tr '\n' ' ')"
  if (( rev_rc != 0 )); then PM_REVISION=NOT_PROVEN; continue; fi
  if ! "$JUST" --summary 2>/dev/null | tr ' ' '\n' | grep -qx 'app-test'; then
    echo "CHECK app-test app=$app APP_TEST=BLOCKED reason=just_app_test_recipe_absent"; any_block=1; continue
  fi
  t_out=$("$JUST" app-test "$app" "$ns" --phase runtime --cluster "$cluster" 2>&1); t_rc=$?
  t=$(grep -E '^APP_TEST=(PASS|FAIL|BLOCKED)$' <<<"$t_out" | tail -1 | cut -d= -f2)
  [[ -n $t ]] || t=BLOCKED
  dh=$(grep -E '^DEPLOY_HEALTH=(PASS|FAIL|UNKNOWN)$' <<<"$t_out" | tail -1 | cut -d= -f2)
  case ${dh:-UNKNOWN} in FAIL) deploy_fail=1 ;; PASS) ;; *) deploy_unknown=1 ;; esac
  ids=$(sed -n 's/^CHECK \([a-z]*\) FAIL .*/\1/p' <<<"$t_out" | paste -sd, -)
  [[ -z $ids ]] || failed_ids="${failed_ids:+$failed_ids,}$app:$ids"
  grep -E '^CHECK ' <<<"$t_out" | sed 's/^/  /' | head -40
  echo "CHECK app-test app=$app APP_TEST=$t DEPLOY_HEALTH=${dh:-UNKNOWN} exit=$t_rc"
  case $t in FAIL) any_fail=1 ;; PASS) ;; *) any_block=1 ;; esac
done
if (( any_fail )); then PM_APP_TEST=FAIL; elif (( any_block )); then PM_APP_TEST=BLOCKED; fi
(( ${#app_lines[@]} )) || PM_APP_TEST=NOT_RUN
# Deployment health: one broken app is enough; PASS only if every app reported PASS.
if (( deploy_fail )); then PM_DEPLOY=FAIL; elif (( deploy_unknown )); then PM_DEPLOY=UNKNOWN; else PM_DEPLOY=PASS; fi
(( ${#app_lines[@]} )) || PM_DEPLOY=UNKNOWN

export PM_CLASS PM_IS_REVERT PM_REVERT_ATTEMPTED PM_NEWER_COMMIT PM_STATEFUL PM_REVISION PM_APP_TEST PM_DEPLOY
pm_decide
echo "FACTS class=$PM_CLASS is_revert=$PM_IS_REVERT revert_attempted=$PM_REVERT_ATTEMPTED newer_commit=$PM_NEWER_COMMIT stateful=$PM_STATEFUL revision=$PM_REVISION app_test=$PM_APP_TEST deploy=$PM_DEPLOY"
echo "DECISION=$PM_DECISION"
echo "REASON=$PM_REASON"
[[ -z $PM_EXTRA ]] || echo "EXTRA=$PM_EXTRA"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  { echo "decision=$PM_DECISION"; echo "reason=$PM_REASON"; echo "stateful=$PM_STATEFUL"; echo "sha=$sha"; } >>"$GITHUB_OUTPUT"
fi

# --- actions
short=${sha:0:12}; ndry=(); (( dry )) && ndry=(--dry-run)
msg="$subject ($short): $PM_REASON"
[[ -z $failed_ids ]] || msg="$msg (checks FAIL: ${failed_ids:0:200})"
[[ $PM_EXTRA == verify-migration ]] && msg="$msg. App avec etat : verifier la migration, le revert ne restaure pas les donnees."
case $PM_DECISION in
  REVERT)
    st=(); [[ $PM_STATEFUL == yes ]] && st=(--stateful)
    if (( dry )); then
      bash scripts/post-merge-revert.sh --dry-run "$sha" ${st[@]+"${st[@]}"} --reason "$PM_REASON"
      bash scripts/post-merge-notify.sh --dry-run "kube-ops post-merge REVERT" "$PM_PRIORITY" "$msg"
    fi
    # Real run: the revert job of the workflow opens the PR with the bot identity, then announces it.
    ;;
  NOTIFY|ESCALATE) bash scripts/post-merge-notify.sh ${ndry[@]+"${ndry[@]}"} "kube-ops post-merge $PM_DECISION" "$PM_PRIORITY" "$msg" ;;
  NONE) ;;
esac
if [[ $PM_DECISION == NONE ]]; then echo "POST_MERGE=PASS"; exit 0; fi
if [[ $PM_DECISION == NOTIFY ]]; then echo "POST_MERGE=BLOCKED"; exit 0; fi
echo "POST_MERGE=FAIL"; exit 1
