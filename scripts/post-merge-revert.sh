#!/usr/bin/env bash
# Opens the automatic revert PR of a merge commit (PLT-390 lot 3). One attempt per commit: the branch name
# is deterministic (claude/post-merge-revert-<sha12>), so a second call finds it and refuses.
# Identity: the caller provides GH_TOKEN of the dedicated revert bot (GitHub App installation token, minted in
# the workflow by actions/create-github-app-token). A GITHUB_TOKEN cannot do it: PRs it opens do not start the
# required checks. Never GH_TOKEN of a person. The PR is a normal PR under the required checks, auto-merge on.
# Usage: bash scripts/post-merge-revert.sh [--dry-run] SHA [--stateful] [--reason TEXT]
# Output: REVERT_PR=<url>|DRY_RUN|REFUSED|CONFLICT|BLOCKED, REVERT_BRANCH=..
set -euo pipefail
dry=0; [[ ${1:-} == --dry-run ]] && { dry=1; shift; }
sha=${1:?usage: post-merge-revert.sh [--dry-run] SHA [--stateful] [--reason TEXT]}; shift
stateful=no; reason="app-test FAIL"
while [[ $# -gt 0 ]]; do
  case "$1" in --stateful) stateful=yes; shift ;; --reason) reason=${2:?}; shift 2 ;; *) echo "bad arg $1" >&2; exit 2 ;; esac
done
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: SHA must be 40 hex chars" >&2; exit 2; }
GH=${GH_BIN:-gh}
short=${sha:0:12}; branch=claude/post-merge-revert-$short; label=post-merge-revert
subject=$(git log -1 --format=%s "$sha")
orig=${subject:0:60}
title="revert: ${orig} (post-merge ${short})"
run() { if (( dry )); then printf 'DRY_RUN %s\n' "$*"; else "$@"; fi; }

echo "REVERT_BRANCH=$branch"
if [[ -n $("$GH" pr list --state all --head "$branch" --json number --jq '.[].number' 2>/dev/null || true) ]] \
  || git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  echo "REVERT_PR=REFUSED reason=already_attempted"; exit 1
fi
parents=$(git rev-list --parents -n1 "$sha" | wc -w); parents=$((parents - 1))
mflag=(); (( parents > 1 )) && mflag=(-m 1)

body=$(cat <<BODY
Revert automatique de \`$sha\` (\`$subject\`), ouvert par la vérification post-merge (PLT-390 lot 3).

- Motif : $reason
- Règles (PLT-141) : un seul revert par commit, jamais un revert de revert, pas de revert si un commit plus récent touche la même app ou si le commit touche autre chose que des apps. Si ce revert échoue aussi, escalade vers Paul.
- Le revert **ne restaure pas les données**. Il remet les manifestes dans l'état précédent ; aucune migration de base ni aucun contenu de volume n'est annulé.
$( [[ $stateful == yes ]] && echo '- **App avec état (PVC ou CNPG) : vérifier la migration et les données avant de considérer la prod restaurée.**' )

Post-merge-revert-of: $sha

Checks run : aucun dans cette PR ; les checks requis tournent normalement, l'auto-merge attend leur résultat. Checks not run : \`just app-test\` après le revert (lancé par le workflow post-merge au merge du revert).
BODY
)

if (( dry )); then
  echo "DRY_RUN git switch -c $branch origin/main && git revert --no-edit ${mflag[*]:-} $sha"
else
  git switch -c "$branch" origin/main >/dev/null 2>&1 || git switch -c "$branch" >/dev/null
  if ! git revert --no-edit ${mflag[@]+"${mflag[@]}"} "$sha" >/dev/null 2>&1; then
    git revert --abort >/dev/null 2>&1 || true
    echo "REVERT_PR=CONFLICT reason=revert_does_not_apply_cleanly"; exit 1
  fi
fi
run git push origin "$branch"
"$GH" label create "$label" --color B60205 --description "Revert automatique post-merge (PLT-390)" >/dev/null 2>&1 || true
if (( dry )); then
  echo "DRY_RUN $GH pr create --base main --head $branch --label $label --title \"$title\" (body: $(wc -l <<<"$body") lines, stateful=$stateful)"
  echo "DRY_RUN $GH pr merge --auto --squash <pr>"
  echo "REVERT_PR=DRY_RUN"; exit 0
fi
url=$("$GH" pr create --base main --head "$branch" --label "$label" --title "$title" --body "$body")
"$GH" pr merge --auto --squash "$url" >/dev/null
echo "REVERT_PR=$url"
