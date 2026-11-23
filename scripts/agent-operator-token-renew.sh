#!/usr/bin/env bash
# Renouvellement automatique du jeton agent-operator de 24 h (PLT-420, suite de PLT-312 M5).
#
# Sans renouvellement, l'identité agent expire et kubectl-ro.sh (défaut `agent`, plus de repli opérateur)
# refuse avec exit 2. Ce script est fait pour tourner sur le Mac de Paul (launchd, toutes les 12 h, voir
# scripts/launchd/dev.smadja.agent-operator-token-renew.plist et docs/operations/agent-operator-token-renewal.md) :
# il appelle `agent-operator-token.sh --provision` (qui exige l'accès opérateur canonique et le Doppler
# de Paul : un agent ne le lance pas). Sortie : statuts seulement, jamais de jeton.
#
#   bash scripts/agent-operator-token-renew.sh            renouvelle (échec = exit non nul, ntfy si NTFY_TOPIC_URL)
#   bash scripts/agent-operator-token-renew.sh --dry      affiche ce qui serait lancé, ne touche à rien
#
# Environnement : AGENT_TOKEN_SCRIPT (tests), NTFY_TOPIC_URL (alerte d'échec optionnelle),
# AGENT_RENEW_LOCK_DIR (défaut ${TMPDIR:-/tmp}/agent-operator-token-renew.lock).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOKEN_SCRIPT=${AGENT_TOKEN_SCRIPT:-$HERE/agent-operator-token.sh}
LOCK=${AGENT_RENEW_LOCK_DIR:-${TMPDIR:-/tmp}/agent-operator-token-renew.lock}
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export AGENT_TOKEN_DURATION=24h

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(stamp) agent-operator-token-renew: $*"; }

if [ "${1:-}" = --dry ]; then
  say "DRY: AGENT_TOKEN_DURATION=$AGENT_TOKEN_DURATION bash $TOKEN_SCRIPT --provision"
  exit 0
fi
[ "$#" = 0 ] || { say "usage : [--dry]" >&2; exit 64; }

# un seul renouvellement à la fois ; un verrou resté plus de 30 min est périmé
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { say "verrou occupé"; exit 75; }
  else
    say "verrou occupé : un renouvellement est déjà en cours"; exit 75
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

bash "$TOKEN_SCRIPT" --provision
rc=$?
if [ "$rc" = 0 ]; then
  say "RENEW=PASS (jeton 24 h écrit dans Doppler et vérifié)"
  exit 0
fi
say "RENEW=FAIL (exit $rc) : l'identité agent expirera ; relancer à la main : AGENT_TOKEN_DURATION=24h bash scripts/agent-operator-token.sh --provision" >&2
if [ -n "${NTFY_TOPIC_URL:-}" ]; then
  curl -fsS -m 10 -H "Title: agent-operator token renew FAILED" -d "exit $rc, voir docs/operations/agent-operator-token-renewal.md" "$NTFY_TOPIC_URL" >/dev/null 2>&1 || true
fi
exit "$rc"
