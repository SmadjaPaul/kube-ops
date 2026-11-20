#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
selector="$repo_root/scripts/select-v1-contract-roots.sh"

assert_scope() {
  local expected="$1" files="$2" actual
  actual="$(V1_CHANGED_FILES="$files" bash "$selector")"
  [[ "$actual" == "$expected" ]] || {
    echo "expected scope $expected, got $actual for $files" >&2
    exit 1
  }
}

assert_scope 'k8s/infrastructure/network/policies/auth,k8s/optional/sparkyfitness' $'k8s/optional/sparkyfitness/networkpolicy.yaml\nk8s/infrastructure/network/policies/auth/allow-authentik-access.yaml'
assert_scope 'k8s/applications/media' 'k8s/applications/media/polyfin/networkpolicy.yaml'
assert_scope all 'k8s/infrastructure/controllers/argocd/kustomization.yaml'
assert_scope all 'unknown-scope/file.txt'
# PLT CI ciblée : chemins sans effet sur le rendu -> rendu de fumée seul.
assert_scope k8s/infrastructure/network/policies/auth 'docs/operations/anything.md'
assert_scope k8s/infrastructure/network/policies/auth $'.agents/skills/x/SKILL.md\nk8s/clusters/oracle-a1/README.md'
# Un chemin de rendu mélangé à un chemin neutre garde le rendu ciblé.
assert_scope k8s/applications/media $'docs/a.md\nk8s/applications/media/x/y.yaml'
# Un chemin hors liste mélangé à un chemin neutre reste complet.
assert_scope all $'docs/a.md\nscripts/foo.sh'
assert_scope all ''

missing_ref_scope="$(GITHUB_EVENT_NAME=pull_request GITHUB_BASE_SHA=missing GITHUB_HEAD_SHA=missing bash "$selector")"
[[ "$missing_ref_scope" == all ]] || { echo 'missing GitHub refs must fail closed to all' >&2; exit 1; }

# merge_group : base_sha/head_sha manquants ou illisibles -> complet (jamais un PASS vide).
mg_scope="$(GITHUB_EVENT_NAME=merge_group GITHUB_BASE_SHA=missing GITHUB_HEAD_SHA=missing bash "$selector")"
[[ "$mg_scope" == all ]] || { echo 'merge_group with unreadable shas must fail closed to all' >&2; exit 1; }
[[ "$(GITHUB_EVENT_NAME=merge_group bash "$selector")" == all ]] || { echo 'merge_group without shas must be all' >&2; exit 1; }
# merge_group avec de vrais commits : le diff base..head est celui de la file (ici docs seuls -> fumee, hors perimetre garde -> skip).
mg_tmp="$(mktemp -d)"; trap 'rm -rf "$mg_tmp"' EXIT
git -C "$mg_tmp" init -q && git -C "$mg_tmp" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
mg_base="$(git -C "$mg_tmp" rev-parse HEAD)"
mkdir -p "$mg_tmp/docs" && echo x > "$mg_tmp/docs/a.md" && git -C "$mg_tmp" add . && git -C "$mg_tmp" -c user.name=t -c user.email=t@t commit -q -m docs
mg_head="$(git -C "$mg_tmp" rev-parse HEAD)"
[[ "$(cd "$mg_tmp" && GITHUB_EVENT_NAME=merge_group GITHUB_BASE_SHA=$mg_base GITHUB_HEAD_SHA=$mg_head bash "$selector")" == k8s/infrastructure/network/policies/auth ]] || { echo 'merge_group docs-only diff must select the smoke root' >&2; exit 1; }
mkdir -p "$mg_tmp/tests/harness" && echo x > "$mg_tmp/tests/harness/service-contract-guard.py" && git -C "$mg_tmp" add . && git -C "$mg_tmp" -c user.name=t -c user.email=t@t commit -q -m guard
mg_head2="$(git -C "$mg_tmp" rev-parse HEAD)"
[[ "$(cd "$mg_tmp" && GITHUB_EVENT_NAME=merge_group GITHUB_BASE_SHA=$mg_base GITHUB_HEAD_SHA=$mg_head2 bash "$selector")" == all ]] || { echo 'merge_group touching tests/harness must render all' >&2; exit 1; }

if V1_CHANGED_FILES='k8s/optional/does-not-exist/file.yaml' V1_CONTRACT_ROOTS='k8s/optional/does-not-exist' bash "$repo_root/scripts/check-v1-active-contract.sh" >/dev/null 2>&1; then
  echo 'unknown render root must fail closed' >&2
  exit 1
fi

echo 'V1_CONTRACT_SCOPE_TEST=PASS'
