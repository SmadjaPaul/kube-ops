#!/usr/bin/env bash
# End-to-end contract test of the post-merge verification (mapping, guards, dry-run) on a throwaway git
# repository with fake just / gh / verify-revision. No cluster, no network, no write in the repository.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/post-merge-verify-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
r="$tmp/repo"; mkdir -p "$r/scripts/lib" "$tmp/bin"
cp "$repo_root"/scripts/post-merge-*.sh "$r/scripts/"; cp "$repo_root/scripts/lib/post-merge-decision.sh" "$r/scripts/lib/"
cd "$r"
git init -q -b main; git config user.email t@t; git config user.name t
mkdir -p k8s/applications/media/prowlarr k8s/applications/media/bookorbit k8s/applications/tools/it-tools k8s/applications/tools/migrated k8s/applications/business/ledger k8s/applications/platform/x k8s/infrastructure/net k8s/applications/tools/okeapp
printf 'namespace: media\nresources: [app.yaml]\n' >k8s/applications/media/prowlarr/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/media/prowlarr/app.yaml
printf 'namespace: media\n' >k8s/applications/media/bookorbit/kustomization.yaml; echo 'kind: PersistentVolumeClaim' >k8s/applications/media/bookorbit/pvc.yaml
printf 'resources: []\n' >k8s/applications/tools/it-tools/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/tools/it-tools/d.yaml
printf 'namespace: migrated\n' >k8s/applications/tools/migrated/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/tools/migrated/d.yaml
printf 'name: migrated\nnamespace: migrated\n' >k8s/applications/tools/migrated/argocd-app.yaml   # per-app Application (PLT-394)
printf 'name: ledger\nnamespace: ledger\n' >k8s/applications/business/ledger/argocd-app.yaml; echo 'kind: Deployment' >k8s/applications/business/ledger/d.yaml
printf 'name: okeapp\nnamespace: okeapp\ncluster: oracle-a1\n' >k8s/applications/tools/okeapp/argocd-app.oracle-a1.yaml; printf 'namespace: okeapp\n' >k8s/applications/tools/okeapp/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/tools/okeapp/d.yaml   # OKE descriptor (PLT-407)
echo x >k8s/applications/platform/x/a.yaml; echo x >k8s/infrastructure/net/a.yaml
git add -A; git commit -qm "chore: base"
commit() { git add -A; git commit -qm "$1"; git rev-parse HEAD; } # prints sha

# Fakes. just: recipe list and app-test verdict from $FX_APPTEST (per call: PASS|FAIL|BLOCKED). gh: no PR, no label.
cat >"$tmp/bin/just" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --summary) [[ ${FX_NORECIPE:-} == 1 ]] && echo "check" || echo "check app-test" ;;
  app-test) echo "$*" >>"${FX_JUST_LOG:-/dev/null}"; echo "CHECK probe app=$2 ns=$3 result=x"; [[ -z ${FX_CHECKS:-} ]] || printf '%b\n' "$FX_CHECKS"
    [[ -z ${FX_DEPLOY:-} ]] || echo "DEPLOY_HEALTH=$FX_DEPLOY"; echo "APP_TEST=${FX_APPTEST:-PASS}"; [[ ${FX_APPTEST:-PASS} == PASS ]] ;;
esac
SH
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ -z ${FX_GH_FAIL:-} ]] || { echo "gh: HTTP 403 (no token)" >&2; exit 1; }
[[ $1 == pr && $2 == list && -n ${FX_PR_EXISTS:-} ]] && echo 7
exit 0
SH
cat >"$tmp/bin/vrev" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${FX_VREV_LOG:-/dev/null}"
if [[ ${FX_REV:-ok} == degraded ]]; then echo "ARGO=Synced/Degraded"; echo "HEALTH=Degraded"; echo "REVISION=PROVEN"; echo "VERIFY_REVISION=PASS"
elif [[ ${FX_REV:-ok} == ok ]]; then echo "ARGO=Synced/Healthy"; echo "REVISION=PROVEN"; echo "VERIFY_REVISION=PASS"; else echo "REVISION=NOT_PROVEN"; echo "LAST_ERROR=timeout"; exit 1; fi
SH
chmod +x "$tmp/bin"/*
run() { # want_exit args...
  local want=$1; shift; set +e
  out=$(JUST_BIN="$tmp/bin/just" GH_BIN="$tmp/bin/gh" VERIFY_REVISION_BIN="$tmp/bin/vrev" PM_MAIN_REF=HEAD bash scripts/post-merge-verify.sh "$@" 2>&1); got=$?
  set -e
  [[ $got -eq $want ]] || { echo "FAIL: exit $got, want $want for: $*"; echo "$out"; exit 1; }
}
expect() { [[ $out == *"$1"* ]] || { echo "FAIL: output lacks '$1'"; echo "$out"; exit 1; }; }
refute() { [[ $out != *"$1"* ]] || { echo "FAIL: output has '$1'"; echo "$out"; exit 1; }; }

# --- mapping
echo y >>k8s/applications/media/prowlarr/app.yaml; echo y >>k8s/applications/tools/it-tools/d.yaml; echo y >>k8s/applications/tools/migrated/d.yaml; echo doc >README.md
s1=$(commit "feat(media): two apps")
out=$(bash scripts/post-merge-affected.sh "$s1")
expect "AFFECTED_APP name=prowlarr namespace=media argo=apps-media stateful=no"
expect "AFFECTED_APP name=it-tools namespace=it-tools argo=apps-tools stateful=no"
expect "AFFECTED_APP name=migrated namespace=migrated argo=app-migrated stateful=no"   # descriptor: Application app-<name>
refute "argo=apps-migrated"
expect "name=prowlarr namespace=media argo=apps-media stateful=no cluster=homelab"   # homelab unchanged
expect "name=migrated namespace=migrated argo=app-migrated stateful=no cluster=homelab"
echo y >>k8s/applications/business/ledger/d.yaml; s1b=$(commit "feat(business): ledger")
out=$(bash scripts/post-merge-affected.sh "$s1b"); expect "AFFECTED_APP name=ledger namespace=ledger argo=app-ledger stateful=no"   # domain business, no special case
expect "AFFECTED_CLASS=apps-only"            # README.md is documentation: ignored
echo y >>k8s/applications/media/bookorbit/pvc.yaml; s2=$(commit "feat(bookorbit): bump")
out=$(bash scripts/post-merge-affected.sh "$s2"); expect "name=bookorbit namespace=media argo=apps-media stateful=yes"
echo y >>k8s/applications/platform/x/a.yaml; s3=$(commit "feat: platform")
out=$(bash scripts/post-merge-affected.sh "$s3"); expect "AFFECTED_CLASS=none"; expect "AFFECTED_OTHER count=1"
echo y >>k8s/applications/media/prowlarr/app.yaml; echo y >>k8s/infrastructure/net/a.yaml; s4=$(commit "feat: app and infra")
out=$(bash scripts/post-merge-affected.sh "$s4"); expect "AFFECTED_CLASS=mixed"

# --- orchestrator cases (each on its own commit; PM_MAIN_REF=HEAD so a later commit on the same app is "newer")
echo z >>k8s/applications/tools/it-tools/d.yaml; pass_sha=$(commit "feat(tools): it-tools")
FX_APPTEST=PASS run 0 --dry-run "$pass_sha";  expect "DECISION=NONE"; expect "POST_MERGE=PASS"; refute "DRY_RUN"
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$pass_sha";  expect "DECISION=REVERT"; expect "DRY_RUN git switch -c claude/post-merge-revert-${pass_sha:0:12}"; expect "DRY_RUN git push"; expect "--label post-merge-revert"; expect "pr merge --auto"; expect "NOTIFY=DRY_RUN"
FX_APPTEST=BLOCKED run 0 --dry-run "$pass_sha"; expect "DECISION=NOTIFY"; expect "POST_MERGE=BLOCKED"; refute "DRY_RUN git switch"
FX_NORECIPE=1 run 0 --dry-run "$pass_sha"; expect "just_app_test_recipe_absent"; expect "DECISION=NOTIFY"
FX_REV=timeout FX_DEPLOY=FAIL FX_APPTEST=FAIL run 0 --dry-run "$pass_sha"; expect "revision_not_proven"; refute "DECISION=REVERT"
FX_PR_EXISTS=1 FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$pass_sha"; expect "DECISION=ESCALATE"; expect "already_reverted"; refute "DRY_RUN git switch"
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$s4";        expect "DECISION=ESCALATE"; expect "more_than_apps"     # app + infra: no revert
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$s2";        expect "DECISION=ESCALATE"; expect "stateful=yes"; expect "verify-migration"; expect "stateful_app_no_auto_revert"; refute "DRY_RUN git switch"   # PVC: no auto-revert (PLT-398)
# Synced at the commit but Degraded: verify-revision (called with --allow-unhealthy) proves the revision, app-test judges.
FX_VREV_LOG="$tmp/vrev.log" FX_REV=degraded FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$pass_sha"; expect "DECISION=REVERT"; expect "HEALTH=Degraded"; expect "revision=PROVEN"
grep -q -- '--allow-unhealthy' "$tmp/vrev.log" || { echo "FAIL: verify-revision not called with --allow-unhealthy"; exit 1; }
FX_REV=degraded FX_APPTEST=PASS run 0 --dry-run "$pass_sha"; expect "DECISION=NONE"
echo w >>k8s/applications/tools/it-tools/d.yaml; commit "fix(tools): newer" >/dev/null
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$pass_sha";  expect "newer_commit_touches_same_app"; expect "DECISION=ESCALATE"; refute "DRY_RUN git switch"
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 0 --dry-run "$s3";        expect "no_app_touched"   # platform-only commit: not an app, nothing to revert
# revert of a revert: refused
echo q >>k8s/applications/media/prowlarr/app.yaml; rv=$(commit "revert: feat(media): two apps (post-merge abcdef123456)")
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$rv";        expect "revert_of_revert_refused"; refute "DRY_RUN git switch"
FX_APPTEST=PASS run 0 --dry-run "$rv";        expect "revert_verified_prod_restored"
# Trailer on main marks the commit as already reverted.
echo p >>k8s/applications/tools/it-tools/d.yaml; t1=$(commit "feat(tools): t1")
git commit -q --allow-empty -m "revert: x" -m "Post-merge-revert-of: $t1"
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$t1";        expect "already_reverted"
# Golden-path debt without a broken deployment: notify, never revert (PLT-390).
echo v >>k8s/applications/tools/it-tools/d.yaml; g=$(commit "chore(tools): renovate bump")
FX_APPTEST=FAIL FX_DEPLOY=PASS FX_CHECKS='CHECK oidc FAIL tasks.smadja.dev/ repond 200 sans cookie\nCHECK network FAIL label PSA enforce=absent' run 0 --dry-run "$g"
expect "DECISION=NOTIFY"; expect "golden_path_fail_no_revert"; expect "checks FAIL: it-tools:oidc,network"; refute "DRY_RUN git switch"; refute "DECISION=REVERT"
FX_APPTEST=FAIL FX_DEPLOY=UNKNOWN FX_CHECKS='CHECK selfheal FAIL aucun pod de l app dans it-tools' run 0 --dry-run "$g"
expect "DECISION=NOTIFY"; expect "golden_path_fail_no_revert"; refute "DRY_RUN git switch"
FX_APPTEST=FAIL FX_CHECKS='CHECK oidc FAIL x' run 0 --dry-run "$g"; expect "DECISION=NOTIFY"   # old app-test without DEPLOY_HEALTH: safe
FX_APPTEST=FAIL FX_DEPLOY=FAIL FX_CHECKS='CHECK oidc FAIL x\nCHECK selfheal FAIL pods non Ready: it-tools-abc' run 1 --dry-run "$g"
expect "DECISION=REVERT"; expect "deploy=FAIL"; expect "DRY_RUN git switch"
# PLT-398: guards must not be blind. gh failing (no token, API down) is not "no revert attempted": fail safe.
FX_GH_FAIL=1 FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$g"; expect "DECISION=ESCALATE"; refute "DRY_RUN git switch"; expect "GUARD_UNKNOWN"
FX_GH_FAIL=1 FX_APPTEST=PASS run 0 --dry-run "$g"; expect "DECISION=NONE"
# One wait per Argo Application: two apps of the same domain call verify-revision once; global deadline passed down.
echo m1 >>k8s/applications/media/prowlarr/app.yaml; echo m2 >>k8s/applications/media/bookorbit/pvc.yaml; two=$(commit "feat(media): two media apps")
rm -f "$tmp/vrev.log"; FX_VREV_LOG="$tmp/vrev.log" FX_APPTEST=PASS run 0 --dry-run "$two"; expect "CHECK app-test app=prowlarr"; expect "CHECK app-test app=bookorbit"
[[ $(grep -c '^apps-media ' "$tmp/vrev.log") == 1 ]] || { echo "FAIL: apps-media waited more than once:"; cat "$tmp/vrev.log"; exit 1; }
grep -q -- '--deadline [0-9]' "$tmp/vrev.log" || { echo "FAIL: no global --deadline passed"; cat "$tmp/vrev.log"; exit 1; }
FX_REV=timeout FX_APPTEST=PASS run 0 --dry-run "$two"; expect "app=bookorbit argo=apps-media REVISION=NOT_PROVEN"   # cached verdict applies to both apps
# Multi-commit push: tip touches docs only, the first commit touches an app. --base (github.event.before) sees both.
echo n >>k8s/applications/tools/it-tools/d.yaml; first=$(commit "feat(tools): first of push")
echo d >>README.md; tip=$(commit "docs: tip of push")
FX_APPTEST=PASS run 0 --dry-run "$tip"; expect "AFFECTED_CLASS=none"; expect "no_app_touched"
FX_APPTEST=PASS run 0 --dry-run "$tip" --base "$(git rev-parse "$first^")"; expect "AFFECTED_APP name=it-tools"; expect "DECISION=NONE"
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 0 --dry-run "$tip" --base 0000000000000000000000000000000000000000; expect "AFFECTED_CLASS=none"   # first push / unknown base: tip only
out=$(bash scripts/post-merge-affected.sh "$tip" "$(git rev-parse "$first^")"); expect "AFFECTED_APP name=it-tools"
# Secrets never printed; usage errors.
run 2 --bogus
# Every CLI the CI job calls must be installed by ci-install-tools.sh: a missing gh made the loop guards
# GUARD_UNKNOWN on the runner, hence ESCALATE instead of REVERT (PLT-398 dry-run drill, 21/11).
for tool in gh kubectl jq yq kustomize helm; do
  grep -q "^need $tool " "$repo_root/scripts/ci-install-tools.sh" || { echo "FAIL: ci-install-tools.sh does not install $tool"; exit 1; }
done

# --- OKE (PLT-407): argocd-app.oracle-a1.yaml -> app-<name>, cluster=oracle-a1, checked on oracle-a1, never reverted
echo o1 >>k8s/applications/tools/okeapp/d.yaml; oke=$(commit "feat(tools): okeapp")
out=$(bash scripts/post-merge-affected.sh "$oke"); expect "AFFECTED_APP name=okeapp namespace=okeapp argo=app-okeapp stateful=no cluster=oracle-a1"; refute "apps-tools"
rm -f "$tmp/vrev.log" "$tmp/just.log"
FX_VREV_LOG="$tmp/vrev.log" FX_JUST_LOG="$tmp/just.log" FX_APPTEST=PASS run 0 --dry-run "$oke"; expect "DECISION=NONE"; expect "CHECK revision cluster=oracle-a1 app=okeapp argo=app-okeapp"
grep -q -- 'app-okeapp .* --cluster oracle-a1' "$tmp/vrev.log" || { echo "FAIL: verify-revision not called with --cluster oracle-a1"; cat "$tmp/vrev.log"; exit 1; }
grep -q -- 'app-test okeapp okeapp --phase runtime --cluster oracle-a1' "$tmp/just.log" || { echo "FAIL: app-test not called with --cluster oracle-a1"; cat "$tmp/just.log"; exit 1; }
# --only-cluster (PLT-407): each cluster's runner verifies its own apps only
FX_VREV_LOG="$tmp/vrev2.log" FX_APPTEST=PASS run 0 --dry-run --only-cluster oracle-a1 "$oke"; expect "ONLY_CLUSTER=oracle-a1 apps=1"; expect "CHECK revision cluster=oracle-a1"
FX_VREV_LOG="$tmp/vrev3.log" FX_APPTEST=FAIL FX_DEPLOY=FAIL run 0 --dry-run --only-cluster homelab "$oke"; expect "ONLY_CLUSTER=homelab apps=0"; expect "DECISION=NONE"; expect "no_app_touched"; refute "CHECK revision"
[[ ! -s "$tmp/vrev3.log" ]] || { echo "FAIL: homelab runner called verify-revision for an OKE app"; cat "$tmp/vrev3.log"; exit 1; }
run 2 --only-cluster mars "$oke"; expect "--only-cluster"
# a broken OKE deployment is a NOTIFY, never a revert PR (no auto-revert there)
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 0 --dry-run "$oke"; expect "DECISION=NOTIFY"; expect "oke_notify_only_no_revert"; expect "oke=yes"; refute "DRY_RUN git switch"; refute "DECISION=REVERT"
FX_REV=timeout FX_DEPLOY=FAIL FX_APPTEST=FAIL run 0 --dry-run "$oke"; expect "revision_not_proven"
# homelab still reverts in the same harness (behaviour unchanged)
echo h1 >>k8s/applications/business/ledger/d.yaml; g=$(commit "fix(business): ledger again")
FX_DEPLOY=FAIL FX_APPTEST=FAIL run 1 --dry-run "$g"; expect "DECISION=REVERT"; expect "oke=no"
rm -f "$tmp/just.log"; FX_JUST_LOG="$tmp/just.log" FX_APPTEST=PASS run 0 --dry-run "$g"
grep -q -- '--cluster homelab' "$tmp/just.log" || { echo "FAIL: homelab app-test lost --cluster homelab"; exit 1; }
echo "post-merge verify test: PASS"
