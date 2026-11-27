#!/usr/bin/env bash
# PLT-562 : tests hors réseau de scripts/optio/triage.py.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
grep -qx 'tests/harness/optio-triage-test.sh' "$repo_root/scripts/check-bash-tests.list" ||
  { echo "OPTIO_TRIAGE=FAIL reason=not_listed" >&2; exit 1; }
command -v jq >/dev/null || { echo "OPTIO_TRIAGE=BLOCKED reason=jq_required"; exit 2; }

PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/tests/harness/optio-triage-test.py" ||
  { echo "OPTIO_TRIAGE=FAIL" >&2; exit 1; }
echo "OPTIO_TRIAGE=PASS"
