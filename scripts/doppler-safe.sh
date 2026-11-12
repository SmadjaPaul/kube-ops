#!/usr/bin/env bash
# Doppler without printing values (AGENTS.md, Safety).
#
# Usage (project/config default to infrastructure/prd):
#   bash scripts/doppler-safe.sh names  [-p P] [-c C]            names, one per line
#   bash scripts/doppler-safe.sh has    KEY [-p P] [-c C]        "present"/"absent" (exit 0/1)
#   printf %s "$v" | bash scripts/doppler-safe.sh set KEY [-p P] [-c C]   value from stdin only
#   bash scripts/doppler-safe.sh delete KEY... [-p P] [-c C]     -y implied, absence verified
#   bash scripts/doppler-safe.sh run [-p P] [-c C] -- CMD [ARGS...]
#       CMD runs with the secrets injected; its stdout and stderr go through a
#       filter that replaces every injected value (and every other environment
#       value of 8+ characters) with [MASQUÉ]. CMD's exit code is kept.
#
# `doppler secrets set|delete` print the whole secrets table (values included)
# even with --silent: this wrapper sends Doppler's own stdout AND stderr to
# /dev/null and reports only an exit code. Values never appear in arguments.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOPPLER=${DOPPLER_SAFE_BIN:-doppler}
PROJECT=infrastructure
CONFIG=prd

die() { echo "doppler-safe: $*" >&2; exit 64; }

[ "$#" -ge 1 ] || die "sous-commande manquante (names|has|set|delete|run)"
sub=$1; shift

args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--project) [ "$#" -ge 2 ] || die "-p sans valeur"; PROJECT=$2; shift 2 ;;
    -c|--config)  [ "$#" -ge 2 ] || die "-c sans valeur"; CONFIG=$2; shift 2 ;;
    --) shift; break ;;
    -*) die "option inconnue : $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
valid_key() { [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "nom de clé invalide : $1"; }

names() { # names only: parse the JSON keys, never print the JSON itself
  "$DOPPLER" secrets --only-names --json -p "$PROJECT" -c "$CONFIG" 2>/dev/null |
    python3 -I -c 'import json,sys
d=json.load(sys.stdin)
print("\n".join(sorted(d if isinstance(d,(dict,list)) else [])))'
}

case "$sub" in
  names)
    [ "${#args[@]}" -eq 0 ] || die "names ne prend pas d'argument"
    names || { echo "doppler-safe: lecture des noms impossible (auth Doppler ?)" >&2; exit 2; } ;;
  has)
    [ "${#args[@]}" -eq 1 ] || die "has KEY"
    valid_key "${args[0]}"
    list=$(names) || { echo "doppler-safe: lecture des noms impossible" >&2; exit 2; }
    if grep -qx "${args[0]}" <<<"$list"; then echo present; else echo absent; exit 1; fi ;;
  set)
    [ "${#args[@]}" -eq 1 ] || die "set KEY (valeur sur stdin)"
    valid_key "${args[0]}"
    [ ! -t 0 ] || die "set lit la valeur sur stdin (pipe ou fichier), jamais en argument"
    "$DOPPLER" secrets set "${args[0]}" -p "$PROJECT" -c "$CONFIG" --silent --no-interactive >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then echo "${args[0]} : défini"; else echo "${args[0]} : échec (code $rc, sortie Doppler supprimée)" >&2; exit 1; fi ;;
  delete)
    [ "${#args[@]}" -ge 1 ] || die "delete KEY..."
    for k in "${args[@]}"; do valid_key "$k"; done
    "$DOPPLER" secrets delete "${args[@]}" -p "$PROJECT" -c "$CONFIG" -y --silent </dev/null >/dev/null 2>&1
    rc=$?
    list=$(names) || list=""
    left=0
    for k in "${args[@]}"; do
      if grep -qx "$k" <<<"$list"; then echo "$k : toujours présent" >&2; left=1; else echo "$k : absent"; fi
    done
    [ "$rc" -eq 0 ] && [ "$left" -eq 0 ] || { echo "doppler-safe: delete code $rc (sortie Doppler supprimée)" >&2; exit 1; } ;;
  run)
    [ "${#args[@]}" -eq 0 ] || die "run [-p P] [-c C] -- CMD"
    [ "$#" -ge 1 ] || die "run : commande manquante après --"
    exec "$DOPPLER" run -p "$PROJECT" -c "$CONFIG" -- python3 -I "$HERE/lib/doppler-mask.py" -- "$@" ;;
  *) die "sous-commande inconnue : $sub (names|has|set|delete|run)" ;;
esac
