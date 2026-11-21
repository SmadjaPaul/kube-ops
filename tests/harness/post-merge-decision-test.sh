#!/usr/bin/env bash
# Decision table of the post-merge verification (scripts/lib/post-merge-decision.sh), PLT-390 lot 3 / PLT-141.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/post-merge-decision.sh
source "$repo_root/scripts/lib/post-merge-decision.sh"

n=0
case_() { # name want_decision want_reason_substring ; env PM_* set by caller via the defaults below
  local name=$1 want=$2 reason=$3
  pm_decide; n=$((n + 1))
  [[ $PM_DECISION == "$want" ]] || { echo "FAIL [$name]: decision $PM_DECISION, want $want (reason $PM_REASON)"; exit 1; }
  [[ $PM_REASON == *"$reason"* ]] || { echo "FAIL [$name]: reason $PM_REASON, want *$reason*"; exit 1; }
}
base() { PM_APP_TEST=PASS PM_REVISION=PROVEN PM_CLASS=apps-only PM_IS_REVERT=no PM_REVERT_ATTEMPTED=no PM_NEWER_COMMIT=no PM_STATEFUL=no PM_DEPLOY=PASS; }

base;                                case_ "PASS: nothing to do" NONE app_test_pass
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL; case_ "FAIL + deploy FAIL: revert" REVERT deploy_unhealthy
[[ $PM_PRIORITY == urgent && -z $PM_EXTRA ]] || { echo "FAIL: revert priority/extra"; exit 1; }
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_STATEFUL=yes; case_ "FAIL stateful: escalate, never auto-revert (PLT-398)" ESCALATE stateful_app_no_auto_revert
[[ $PM_EXTRA == verify-migration && $PM_PRIORITY == urgent ]] || { echo "FAIL: stateful lacks verify-migration/urgent"; exit 1; }
base; PM_APP_TEST=PASS PM_STATEFUL=yes; case_ "PASS stateful: nothing" NONE app_test_pass
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_STATEFUL=yes PM_CLASS=mixed; case_ "stateful + mixed: mixed reason first" ESCALATE more_than_apps
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_STATEFUL=yes PM_IS_REVERT=yes; case_ "stateful revert: still revert_of_revert" ESCALATE revert_of_revert
base; PM_APP_TEST=BLOCKED;           case_ "BLOCKED: notify, no revert" NOTIFY app_test_BLOCKED
base; PM_APP_TEST=NOT_RUN;           case_ "NOT_RUN: notify, no revert" NOTIFY app_test_NOT_RUN
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_CLASS=mixed;  case_ "FAIL on infra/mixed commit: escalate" ESCALATE more_than_apps
base; PM_APP_TEST=PASS PM_CLASS=mixed;  case_ "PASS on mixed commit: nothing" NONE app_test_pass
base; PM_CLASS=none;                 case_ "no app touched" NONE no_app_touched
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_NEWER_COMMIT=yes; case_ "FAIL, newer commit on same app: escalate" ESCALATE newer_commit
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_REVERT_ATTEMPTED=yes; case_ "FAIL, already reverted: escalate" ESCALATE already_reverted
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_IS_REVERT=yes; case_ "FAIL on a revert: never revert a revert" ESCALATE revert_of_revert
base; PM_IS_REVERT=yes;              case_ "revert verified" NONE revert_verified
base; PM_REVISION=NOT_PROVEN PM_APP_TEST=FAIL PM_DEPLOY=FAIL; case_ "revision not proven: no revert" NOTIFY revision_not_proven
base; PM_REVISION=NOT_PROVEN PM_APP_TEST=PASS; case_ "revision not proven, even if PASS" NOTIFY revision_not_proven
base; PM_APP_TEST=FAIL PM_DEPLOY=PASS; case_ "golden-path FAIL only: notify, no revert" NOTIFY golden_path_fail_no_revert
[[ $PM_PRIORITY == high ]] || { echo "FAIL: golden-path priority"; exit 1; }
base; PM_APP_TEST=FAIL PM_DEPLOY=UNKNOWN; case_ "FAIL, deploy unknown (no pod): notify" NOTIFY golden_path_fail_no_revert
base; PM_APP_TEST=FAIL; unset PM_DEPLOY; case_ "FAIL, PM_DEPLOY unset: notify" NOTIFY golden_path_fail_no_revert
base; PM_APP_TEST=FAIL PM_DEPLOY=PASS PM_CLASS=mixed; case_ "golden-path FAIL on mixed: notify, not escalate" NOTIFY golden_path_fail_no_revert
base; PM_APP_TEST=FAIL PM_DEPLOY=FAIL PM_CLASS=mixed; case_ "deploy FAIL + mixed: escalate" ESCALATE more_than_apps
base; PM_APP_TEST=PASS PM_DEPLOY=FAIL; case_ "deploy FAIL wins over app-test PASS (frozen selfheal debt, drill #1691)" REVERT deploy_unhealthy
base; PM_APP_TEST=BLOCKED PM_DEPLOY=FAIL; case_ "deploy FAIL wins over app-test BLOCKED" REVERT deploy_unhealthy
base; PM_APP_TEST=PASS PM_DEPLOY=FAIL PM_IS_REVERT=yes; case_ "deploy FAIL on a revert: never revert a revert" ESCALATE revert_of_revert
echo "post-merge decision test: PASS ($n cases)"
