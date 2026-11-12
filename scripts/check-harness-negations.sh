#!/usr/bin/env bash
# PLT-210: a bare `! cmd` line never trips `set -e` (a negated command is exempt
# from errexit), so a negative assertion written that way can never fail unless
# it is the last command of the script. Refuse the pattern in the harness
# scripts; write `if cmd; then echo '...' >&2; exit 1; fi` instead.
set -euo pipefail

files=(tests/harness/*.sh scripts/check-*.sh)
if hits="$(grep -nE '^[[:space:]]*![[:space:]]' "${files[@]}")"; then
  echo "ERROR: bare '! cmd' assertion is inoperative under set -e; use 'if cmd; then ...; exit 1; fi':" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "HARNESS_NEGATED_ASSERTIONS=PASS"
