#!/usr/bin/env bash
# PLT-367 / F1 (CRITIQUE, homelab-infra audit): agent-facing instructions never recommend the
# operator-identity access recipes (`just kube-access-check`, `just kube-access-sync`, `just kubectl`).
# Agents read through scripts/kubectl-ro.sh with KUBECTL_RO_IDENTITY=agent (agent-operator).
# Static and offline: reads instruction files only. Usage: bash tests/agent-guard/agent-kube-access-doc-test.sh [root]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$script_dir/../.." && pwd)}"

fail() {
  echo "AGENT_KUBE_ACCESS_DOC=FAIL: $1" >&2
  exit 1
}

agents_md="$root/AGENTS.md"
test -f "$agents_md" || fail "missing $agents_md"

# Agent-facing instruction files: AGENTS.md, CLAUDE.md and every repository skill.
files=("$agents_md")
if test -f "$root/CLAUDE.md"; then
  files+=("$root/CLAUDE.md")
fi
while IFS= read -r skill; do
  files+=("$skill")
done < <(find "$root/.agents/skills" "$root/.claude/skills" -type f -name 'SKILL.md' 2>/dev/null | sort)

# Positive: AGENTS.md states the agent identity switch.
grep -qF -- 'KUBECTL_RO_IDENTITY=agent' "$agents_md" || fail "AGENTS.md does not require KUBECTL_RO_IDENTITY=agent"

# Negative: an operator-identity recipe is allowed in an agent-facing file only on a line
# that reserves it to Paul and names the operator identity.
pattern='just (kube-access-check|kube-access-sync|kubectl)([^a-z-]|$)'
violations=0
for file in "${files[@]}"; do
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -qE "$pattern"; then
      if ! { printf '%s\n' "$line" | grep -qF 'reserved to Paul' && printf '%s\n' "$line" | grep -qF 'operator identity'; }; then
        echo "  $file: $line" >&2
        violations=$((violations + 1))
      fi
    fi
  done <"$file"
done
if [[ "$violations" -gt 0 ]]; then
  fail "$violations agent-facing line(s) recommend the operator identity"
fi

# Negative case (repository run only): a skill recommending `just kube-access-check` must be rejected.
if [[ $# -eq 0 ]]; then
  negative_root="$(mktemp -d)"
  trap 'rm -rf "$negative_root"' EXIT
  cp "$agents_md" "$negative_root/AGENTS.md"
  mkdir -p "$negative_root/.agents/skills/negative"
  # shellcheck disable=SC2016 # the backticks are literal text in the fixture
  printf -- '---\nname: negative\n---\nRun `just kube-access-check` first.\n' >"$negative_root/.agents/skills/negative/SKILL.md"
  if bash "$script_dir/$(basename "${BASH_SOURCE[0]}")" "$negative_root" >/dev/null 2>&1; then
    fail "negative case passed: a skill recommending just kube-access-check was not rejected"
  fi
  echo "AGENT_KUBE_ACCESS_DOC=PASS files=${#files[@]} negative=rejected"
else
  echo "AGENT_KUBE_ACCESS_DOC=PASS files=${#files[@]} root=$root"
fi
