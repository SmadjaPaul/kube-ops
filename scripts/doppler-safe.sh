#!/usr/bin/env bash
# Doppler without printing values (AGENTS.md, Safety).
#
# Usage (project/config default to infrastructure/prd):
#   bash scripts/doppler-safe.sh names  [-p P] [-c C]            names, one per line
#   bash scripts/doppler-safe.sh has    KEY [-p P] [-c C]        "present"/"absent" (exit 0/1)
#   printf %s "$v" | bash scripts/doppler-safe.sh set KEY [-p P] [-c C]   value from stdin only
#   bash scripts/doppler-safe.sh delete KEY... [-p P] [-c C]     -y implied, absence verified
#   bash scripts/doppler-safe.sh run --only KEY[,KEY...] [-p P] [-c C] -- CMD [ARGS...]
#       CMD runs with ONLY the listed secrets injected (--only is mandatory,
#       repeatable, comma lists accepted, at most 16 names, no wildcard; there is
#       no "inject everything" mode). Its stdout and stderr go through a filter
#       that replaces every injected value (and every other environment value
#       of 8+ characters) with [MASQUÉ]. CMD's exit code is kept. A listed name
#       missing from Doppler makes the run fail before CMD starts.
#
# Closed list of project/config pairs (every subcommand): infrastructure/prd
# (default), cluster/prd, apps/prd (PRD-103 removed home/prd_maison: no consumer left). Any
# other pair is refused (exit 64): adding
# one is a reviewed change to ALLOWED_SCOPES below, not a runtime option.
#
# `doppler secrets set|delete` print the whole secrets table (values included)
# even with --silent: this wrapper sends Doppler's own stdout AND stderr to
# /dev/null and reports only an exit code. Values never appear in arguments.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOPPLER=${DOPPLER_SAFE_BIN:-doppler}
PROJECT=infrastructure
CONFIG=prd
ALLOWED_SCOPES="infrastructure/prd cluster/prd apps/prd"
ONLY_MAX=16
only=()

die() { echo "doppler-safe: $*" >&2; exit 64; }

[ "$#" -ge 1 ] || die "sous-commande manquante (names|has|set|delete|run)"
sub=$1; shift

args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--project) [ "$#" -ge 2 ] || die "-p sans valeur"; PROJECT=$2; shift 2 ;;
    -c|--config)  [ "$#" -ge 2 ] || die "-c sans valeur"; CONFIG=$2; shift 2 ;;
    --only)       [ "$#" -ge 2 ] && [ -n "$2" ] || die "--only sans valeur"; IFS=, read -r -a _o <<<"$2"; only+=("${_o[@]}"); shift 2 ;;
    --) shift; break ;;
    -*) die "option inconnue : $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
valid_key() { [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "nom de clé invalide : $1"; }
case " $ALLOWED_SCOPES " in
  *" $PROJECT/$CONFIG "*) ;;
  *) die "projet/config '$PROJECT/$CONFIG' hors liste fermée ($ALLOWED_SCOPES)" ;;
esac
[ "$sub" = run ] || [ "${#only[@]}" -eq 0 ] || die "--only n'existe que pour run"

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
    [ "${#args[@]}" -eq 0 ] || die "run --only KEY[,KEY...] [-p P] [-c C] -- CMD"
    [ "${#only[@]}" -ge 1 ] || die "run exige --only KEY[,KEY...] : plus d'injection de tous les secrets (voir l'en-tête)"
    [ "${#only[@]}" -le "$ONLY_MAX" ] || die "--only : $ONLY_MAX noms au plus"
    for k in "${only[@]}"; do valid_key "$k"; done
    [ "$#" -ge 1 ] || die "run : commande manquante après --"
    only_csv=$(IFS=,; echo "${only[*]}")
    exec "$DOPPLER" run -p "$PROJECT" -c "$CONFIG" --only-secrets "$only_csv" -- python3 -I "$HERE/lib/doppler-mask.py" -- "$@" ;;
  *) die "sous-commande inconnue : $sub (names|has|set|delete|run)" ;;
esac
