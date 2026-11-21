#!/usr/bin/env bash
# Contract test of scripts/post-merge-revert.sh (PLT-398): the revert COMMIT carries the trailer
# `Post-merge-revert-of: <sha>` (the loop guards read the commit on main, not the PR body). Throwaway repo,
# bare origin and fake gh: no network, no write in the repository.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/post-merge-revert-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/w" 2>/dev/null; cd "$tmp/w"
git config user.email t@t; git config user.name t; git checkout -q -b main
mkdir scripts; cp "$repo_root/scripts/post-merge-revert.sh" scripts/
echo a >f; git add -A; git commit -qm "chore: base"; git push -q origin main
echo b >>f; git commit -qam "feat(media): break it"; sha=$(git rev-parse HEAD); git push -q origin main
git fetch -q origin
cat >"$tmp/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") exit 0 ;;
  "pr create") echo "https://example.test/pull/1" ;;
esac
exit 0
SH
chmod +x "$tmp/gh"
out=$(GH_BIN="$tmp/gh" bash scripts/post-merge-revert.sh "$sha" --reason deploy_unhealthy 2>&1) || { echo "FAIL: revert script"; echo "$out"; exit 1; }
[[ $out == *"REVERT_PR=https://example.test/pull/1"* ]] || { echo "FAIL: no PR url"; echo "$out"; exit 1; }
branch="claude/post-merge-revert-${sha:0:12}"
msg=$(git -C "$tmp/origin.git" log -1 --format=%B "$branch")
grep -qx "Post-merge-revert-of: $sha" <<<"$msg" || { echo "FAIL: revert commit lacks the trailer"; echo "$msg"; exit 1; }
[[ $(git -C "$tmp/origin.git" log -1 --format=%s "$branch") == Revert* ]] || { echo "FAIL: subject of the revert commit changed"; exit 1; }
[[ $(git -C "$tmp/origin.git" show "$branch:f") == a ]] || { echo "FAIL: file not reverted"; exit 1; }
git -C "$tmp/origin.git" log "$branch" --grep="Post-merge-revert-of: $sha" --format=%H -n1 | grep -q . || { echo "FAIL: post-merge-verify grep does not match"; exit 1; }
# Second call: refused (one attempt per commit).
git switch -q main; set +e; out=$(GH_BIN="$tmp/gh" bash scripts/post-merge-revert.sh "$sha" 2>&1); rc=$?; set -e
[[ $rc -ne 0 && $out == *"REFUSED"* ]] || { echo "FAIL: second attempt not refused"; echo "$out"; exit 1; }
echo "post-merge revert test: PASS"
