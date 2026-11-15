#!/usr/bin/env bash
# Run CMD with the Authentik service-account token `agent-e2e` and nothing else
# (PLT-57). The token lives in Doppler cluster/prd as APP_AGENT_E2E_TOKEN (the
# same key feeds the Authentik blueprint through the ExternalSecret
# authentik-blueprint-core-secrets). The value is never printed: it reaches CMD
# only as the environment variable AGENT_E2E_TOKEN, and doppler-safe.sh masks it
# in CMD's output.
#
# Usage: bash scripts/agent-e2e-run.sh -- CMD [ARGS...]
#   e.g. bash scripts/agent-e2e-run.sh -- python3 -I my-e2e.py
# Every other cluster/prd variable is dropped before CMD starts.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "agent-e2e-run: usage: agent-e2e-run.sh -- CMD [ARGS...]" >&2; exit 64; }
exec bash "$HERE/doppler-safe.sh" run -p cluster -c prd -- bash -c '
  [ -n "${APP_AGENT_E2E_TOKEN:-}" ] || { echo "agent-e2e-run: APP_AGENT_E2E_TOKEN absent de cluster/prd" >&2; exit 2; }
  export AGENT_E2E_TOKEN="$APP_AGENT_E2E_TOKEN"
  for v in $(compgen -e); do
    case "$v" in
      AGENT_E2E_TOKEN|PATH|HOME|USER|LOGNAME|SHELL|TMPDIR|LANG|LC_*|TERM|TZ|PWD) ;;
      *) unset "$v" ;;
    esac
  done
  exec "$@"
' agent-e2e-run "$@"
