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
mkdir -p k8s/applications/media/prowlarr k8s/applications/media/bookorbit k8s/applications/tools/it-tools k8s/applications/platform/x k8s/infrastructure/net
printf 'namespace: media\nresources: [app.yaml]\n' >k8s/applications/media/prowlarr/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/media/prowlarr/app.yaml
printf 'namespace: media\n' >k8s/applications/media/bookorbit/kustomization.yaml; echo 'kind: PersistentVolumeClaim' >k8s/applications/media/bookorbit/pvc.yaml
printf 'resources: []\n' >k8s/applications/tools/it-tools/kustomization.yaml; echo 'kind: Deployment' >k8s/applications/tools/it-tools/d.yaml
echo x >k8s/applications/platform/x/a.yaml; echo x >k8s/infrastructure/net/a.yaml
git add -A; git commit -qm "chore: base"
commit() { git add -A; git commit -qm "$1"; git rev-parse HEAD; } # prints sha

# Fakes. just: recipe list and app-test verdict from $FX_APPTEST (per call: PASS|FAIL|BLOCKED). gh: no PR, no label.
cat >"$tmp/bin/just" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --summary) [[ ${FX_NORECIPE:-} == 1 ]] && echo "check" || echo "check app-test" ;;
  app-test) echo "CHECK probe app=$2 ns=$3 result=x"; echo "APP_TEST=${FX_APPTEST:-PASS}"; [[ ${FX_APPTEST:-PASS} == PASS ]] ;;
esac
SH
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ $1 == pr && $2 == list && -n ${FX_PR_EXISTS:-} ]] && echo 7
exit 0
SH
cat >"$tmp/bin/vrev" <<'SH'
#!/usr/bin/env bash
if [[ ${FX_REV:-ok} == ok ]]; then echo "ARGO=Synced/Healthy"; echo "REVISION=PROVEN"; echo "VERIFY_REVISION=PASS"; else echo "REVISION=NOT_PROVEN"; echo "LAST_ERROR=timeout"; exit 1; fi
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
echo y >>k8s/applications/media/prowlarr/app.yaml; echo y >>k8s/applications/tools/it-tools/d.yaml; echo doc >README.md
s1=$(commit "feat(media): two apps")
out=$(bash scripts/post-merge-affected.sh "$s1")
expect "AFFECTED_APP name=prowlarr namespace=media argo=apps-media stateful=no"
expect "AFFECTED_APP name=it-tools namespace=it-tools argo=apps-tools stateful=no"
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
FX_APPTEST=FAIL run 1 --dry-run "$pass_sha";  expect "DECISION=REVERT"; expect "DRY_RUN git switch -c claude/post-merge-revert-${pass_sha:0:12}"; expect "DRY_RUN git push"; expect "--label post-merge-revert"; expect "pr merge --auto"; expect "NOTIFY=DRY_RUN"
FX_APPTEST=BLOCKED run 0 --dry-run "$pass_sha"; expect "DECISION=NOTIFY"; expect "POST_MERGE=BLOCKED"; refute "DRY_RUN git switch"
FX_NORECIPE=1 run 0 --dry-run "$pass_sha"; expect "just_app_test_recipe_absent"; expect "DECISION=NOTIFY"
FX_REV=timeout FX_APPTEST=FAIL run 0 --dry-run "$pass_sha"; expect "revision_not_proven"; refute "DECISION=REVERT"
FX_PR_EXISTS=1 FX_APPTEST=FAIL run 1 --dry-run "$pass_sha"; expect "DECISION=ESCALATE"; expect "already_reverted"; refute "DRY_RUN git switch"
FX_APPTEST=FAIL run 1 --dry-run "$s4";        expect "DECISION=ESCALATE"; expect "more_than_apps"     # app + infra: no revert
FX_APPTEST=FAIL run 1 --dry-run "$s2";        expect "DECISION=REVERT"; expect "stateful=yes"; expect "verify-migration"   # PVC: warning
echo w >>k8s/applications/tools/it-tools/d.yaml; commit "fix(tools): newer" >/dev/null
FX_APPTEST=FAIL run 1 --dry-run "$pass_sha";  expect "newer_commit_touches_same_app"; expect "DECISION=ESCALATE"; refute "DRY_RUN git switch"
FX_APPTEST=FAIL run 0 --dry-run "$s3";        expect "no_app_touched"   # platform-only commit: not an app, nothing to revert
# revert of a revert: refused
echo q >>k8s/applications/media/prowlarr/app.yaml; rv=$(commit "revert: feat(media): two apps (post-merge abcdef123456)")
FX_APPTEST=FAIL run 1 --dry-run "$rv";        expect "revert_of_revert_refused"; refute "DRY_RUN git switch"
FX_APPTEST=PASS run 0 --dry-run "$rv";        expect "revert_verified_prod_restored"
# Trailer on main marks the commit as already reverted.
echo p >>k8s/applications/tools/it-tools/d.yaml; t1=$(commit "feat(tools): t1")
git commit -q --allow-empty -m "revert: x" -m "Post-merge-revert-of: $t1"
FX_APPTEST=FAIL run 1 --dry-run "$t1";        expect "already_reverted"
# Secrets never printed; usage errors.
run 2 --bogus
echo "post-merge verify test: PASS"
