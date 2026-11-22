#!/usr/bin/env bash
# PLT-420 : contrat de scripts/agent-operator-token-renew.sh (jeton simulé, aucun accès cluster ni Doppler).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renew="$root/scripts/agent-operator-token-renew.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
n=0; bad=0
ok() { n=$((n + 1)); echo "ok   - $1"; }
ko() { n=$((n + 1)); bad=$((bad + 1)); echo "FAIL - $1"; }
export AGENT_RENEW_LOCK_DIR="$WORK/lock"

cat >"$WORK/fake-ok.sh" <<'F'
#!/bin/sh
echo "$1 duration=$AGENT_TOKEN_DURATION" >>"$FAKE_LOG"
exit 0
F
cat >"$WORK/fake-fail.sh" <<'F'
#!/bin/sh
echo "$1" >>"$FAKE_LOG"
exit 6
F
chmod +x "$WORK"/fake-*.sh
export FAKE_LOG="$WORK/log"

: >"$FAKE_LOG"; out=$(AGENT_TOKEN_SCRIPT="$WORK/fake-ok.sh" bash "$renew" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$FAKE_LOG")" = "--provision duration=24h" ] && grep -q 'RENEW=PASS' <<<"$out" \
  && ok "succès : --provision lancé avec une durée de 24 h" || ko "succès ($rc: $out)"
[ ! -d "$WORK/lock" ] && ok "verrou libéré après succès" || ko "verrou resté"

: >"$FAKE_LOG"; out=$(AGENT_TOKEN_SCRIPT="$WORK/fake-fail.sh" bash "$renew" 2>&1); rc=$?
[ "$rc" = 6 ] && grep -q 'RENEW=FAIL (exit 6)' <<<"$out" && [ ! -d "$WORK/lock" ] \
  && ok "échec : code propagé, message explicite, verrou libéré" || ko "échec ($rc: $out)"

mkdir "$WORK/lock"; : >"$FAKE_LOG"; out=$(AGENT_TOKEN_SCRIPT="$WORK/fake-ok.sh" bash "$renew" 2>&1); rc=$?
[ "$rc" = 75 ] && [ ! -s "$FAKE_LOG" ] && ok "verrou occupé : exit 75, aucun renouvellement concurrent" || ko "verrou ($rc)"
rmdir "$WORK/lock"

: >"$FAKE_LOG"; out=$(AGENT_TOKEN_SCRIPT="$WORK/fake-ok.sh" bash "$renew" --dry 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$FAKE_LOG" ] && grep -q DRY <<<"$out" && ok "--dry : rien n'est lancé" || ko "--dry ($rc)"
bash "$renew" --bogus >/dev/null 2>&1; [ "$?" = 64 ] && ok "argument inconnu refusé (64)" || ko "argument inconnu"

grep -q 'StartInterval</key><integer>43200' "$root/scripts/launchd/dev.smadja.agent-operator-token-renew.plist" \
  && ok "plist : toutes les 12 h (jeton de 24 h, une marge d'un échec)" || ko "plist intervalle"
plutil -lint "$root/scripts/launchd/dev.smadja.agent-operator-token-renew.plist" >/dev/null 2>&1 || ! command -v plutil >/dev/null \
  && ok "plist valide" || ko "plist invalide"

echo "# $((n - bad)) ok, $bad échec(s)"
[ "$bad" = 0 ] && echo AGENT_OPERATOR_TOKEN_RENEW_TEST=PASS
[ "$bad" = 0 ]
