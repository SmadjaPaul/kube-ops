#!/usr/bin/env bash
# Pure decision logic of the post-merge verification (PLT-390 lot 3, rules of PLT-141). Source it, then:
#   PM_APP_TEST=PASS|FAIL|BLOCKED|NOT_RUN  aggregated `just app-test` verdict
#   PM_DEPLOY=PASS|FAIL|UNKNOWN            deployment health (app-test DEPLOY_HEALTH: pods Ready, no recent restarts)
#   PM_REVISION=PROVEN|NOT_PROVEN          Argo Synced+Healthy at the merge commit
#   PM_CLASS=apps-only|mixed|none          what the commit touches (post-merge-affected.sh)
#   PM_IS_REVERT=yes|no                    the commit is itself a post-merge revert
#   PM_REVERT_ATTEMPTED=yes|no             a revert PR/branch for this commit already exists
#   PM_NEWER_COMMIT=yes|no                 a more recent commit touches the same app
#   PM_STATEFUL=yes|no                     an affected app has a PVC or a CNPG Cluster
#   PM_OKE=yes|no                          an affected app runs on OKE (argocd-app.oracle-a1.yaml, PLT-407): never reverted
#   pm_decide   -> sets PM_DECISION (NONE|NOTIFY|REVERT|ESCALATE), PM_REASON, PM_PRIORITY, PM_EXTRA
# Only PM_DEPLOY=FAIL justifies a revert: golden-path debt (oidc, network, backup...) is NOTIFY. Unset = UNKNOWN.
# NONE: nothing to do. NOTIFY: tell Paul, no revert. REVERT: open one auto-merge revert PR + notify.
# ESCALATE: tell Paul urgently, never a revert (one revert per commit, never a revert of a revert, never an auto-revert of a stateful app).
pm_decide() {
  PM_DECISION=NONE; PM_REASON=ok; PM_PRIORITY=default; PM_EXTRA=""
  if [[ ${PM_CLASS:-none} == none ]]; then PM_REASON=no_app_touched; return; fi
  # A broken deployment (DEPLOY_HEALTH=FAIL: pods not Ready, recent restarts) goes to the revert guards even when
  # the aggregated app-test verdict is PASS or BLOCKED: frozen or declared selfheal debt can turn it green (drill #1691).
  [[ ${PM_DEPLOY:-UNKNOWN} == FAIL ]] && PM_APP_TEST=FAIL
  if [[ ${PM_IS_REVERT:-no} == yes ]]; then
    if [[ ${PM_APP_TEST:-} == PASS && ${PM_REVISION:-} == PROVEN ]]; then PM_REASON=revert_verified_prod_restored; return; fi
    PM_DECISION=ESCALATE; PM_REASON=revert_of_revert_refused; PM_PRIORITY=urgent; return
  fi
  if [[ ${PM_REVISION:-} != PROVEN ]]; then
    PM_DECISION=NOTIFY; PM_REASON=revision_not_proven_no_revert; PM_PRIORITY=high; return
  fi
  case ${PM_APP_TEST:-} in
    PASS) PM_REASON=app_test_pass; return ;;
    FAIL) ;;
    *) PM_DECISION=NOTIFY; PM_REASON=app_test_${PM_APP_TEST:-unknown}_no_revert; PM_PRIORITY=high; return ;;
  esac
  # OKE (PLT-407, `postMerge: notify`): no automatic revert there, whatever the deployment health.
  if [[ ${PM_OKE:-no} == yes ]]; then
    PM_DECISION=NOTIFY; PM_REASON=oke_notify_only_no_revert; PM_PRIORITY=high; return
  fi
  # app-test FAIL but the deployment itself is not proven broken: golden-path debt, tell Paul, never revert.
  if [[ ${PM_DEPLOY:-UNKNOWN} != FAIL ]]; then
    PM_DECISION=NOTIFY; PM_REASON=golden_path_fail_no_revert; PM_PRIORITY=high; return
  fi
  # deployment broken: guards, then revert.
  if [[ ${PM_CLASS} == mixed ]]; then
    PM_DECISION=ESCALATE; PM_REASON=commit_touches_more_than_apps_no_revert; PM_PRIORITY=urgent; return
  fi
  if [[ ${PM_NEWER_COMMIT:-no} == yes ]]; then
    PM_DECISION=ESCALATE; PM_REASON=newer_commit_touches_same_app_no_revert; PM_PRIORITY=urgent; return
  fi
  if [[ ${PM_REVERT_ATTEMPTED:-no} == yes ]]; then
    PM_DECISION=ESCALATE; PM_REASON=already_reverted_once_escalate; PM_PRIORITY=urgent; return
  fi
  # Stateful app (PVC or CNPG): the revert does not restore data and may break a schema migration (PLT-398).
  if [[ ${PM_STATEFUL:-no} == yes ]]; then
    PM_DECISION=ESCALATE; PM_REASON=stateful_app_no_auto_revert; PM_PRIORITY=urgent; PM_EXTRA=verify-migration; return
  fi
  PM_DECISION=REVERT; PM_REASON=deploy_unhealthy; PM_PRIORITY=urgent
  return 0
}
