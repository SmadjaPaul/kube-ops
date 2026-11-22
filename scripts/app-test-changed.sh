#!/usr/bin/env bash
# CI : phase statique de app-test pour les applications TOUCHEES par la diff (PLT-390), sans rendre
# rouge le depot : les violations existantes sont gelees dans policy/app-test-baseline.tsv
# (cliquet comme policy/baseline.tsv). Une violation nouvelle, ou un rendu impossible, echoue.
#
#   scripts/app-test-changed.sh              apps touchees par la diff (V1_CHANGED_FILES, ou
#                                            GITHUB_BASE_SHA..GITHUB_HEAD_SHA, ou origin/main...HEAD)
#   scripts/app-test-changed.sh --all        toutes les apps (diagnostic)
#   scripts/app-test-changed.sh --update     reecrit la baseline avec toutes les apps (rendu complet)
#
# Une app = k8s/applications/<groupe>/<app> contenant une kustomization. Un changement qui ne
# touche que app-test.yaml compte comme une modification de l'app (son contrat de test).
set -uo pipefail
cd "$(dirname "$0")/.."
BASELINE=policy/app-test-baseline.tsv
mode=changed
case "${1:-}" in "") ;; --all) mode=all ;; --update) mode=update ;; *) echo "usage: $0 [--all|--update]" >&2; exit 2 ;; esac

all_apps() {
  for d in k8s/applications/*/*/; do
    d=${d%/}
    [[ -f $d/kustomization.yaml || -f $d/kustomization.yml ]] && echo "$d"
  done | sort
}

changed_files() {
  if [[ -n ${V1_CHANGED_FILES:-} ]]; then printf '%s\n' "$V1_CHANGED_FILES"
  elif [[ -n ${GITHUB_BASE_SHA:-} && -n ${GITHUB_HEAD_SHA:-} ]]; then git diff --name-only "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA"
  else git diff --name-only origin/main...HEAD 2>/dev/null; fi
}

if [[ $mode == changed ]]; then
  apps=()
  while IFS= read -r f; do
    [[ $f == k8s/applications/*/*/* ]] || continue
    d="$(cut -d/ -f1-4 <<<"$f")"
    [[ -f $d/kustomization.yaml || -f $d/kustomization.yml ]] && apps+=("$d")
  done < <(changed_files)
  apps=($(printf '%s\n' ${apps[@]+"${apps[@]}"} | sort -u))
else
  apps=($(all_apps))
fi
if ((${#apps[@]} == 0)); then echo "APP_TEST_CHANGED=SKIP aucune application touchee"; exit 0; fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/app-test-changed.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/current.tsv"
blocked=0
for d in "${apps[@]}"; do
  name="$(basename "$d")"
  ns="$name"
  bash scripts/app-test.sh "$name" "$ns" --phase static --app-dir "$d" --no-ratchet >"$tmp/out.$name" 2>&1
  # --app-dir : le nom peut ne pas etre unique, le dossier fait foi
  awk -v app="$name" '$1=="CHECK" && ($3=="FAIL"||$3=="BLOCKED") {print app "\t" $2 "\t" $3}' "$tmp/out.$name" >>"$tmp/current.tsv"
done
sort -u -o "$tmp/current.tsv" "$tmp/current.tsv"

if [[ $mode == update ]]; then
  if grep -q $'\tBLOCKED$' "$tmp/current.tsv"; then echo "APP_TEST_BASELINE=BLOCKED (rendu impossible pour une app)"; grep $'\tBLOCKED$' "$tmp/current.tsv"; exit 2; fi
  {
    echo "# Baseline du cliquet app-test (scripts/app-test-changed.sh) : une ligne = une verification statique en echec : <app><TAB><id><TAB>FAIL."
    echo "# Ne jamais ajouter de ligne a la main pour faire passer une PR : corriger l'app ou declarer une exception justifiee (app-test.yaml)."
    cat "$tmp/current.tsv"
  } >"$BASELINE"
  echo "APP_TEST_BASELINE=UPDATED violations=$(wc -l <"$tmp/current.tsv" | tr -d ' ') apps=${#apps[@]}"
  exit 0
fi

grep -vE '^#|^$' "$BASELINE" 2>/dev/null | sort -u >"$tmp/baseline.tsv" || : >"$tmp/baseline.tsv"
# nouvelles violations : en echec maintenant, absentes de la baseline (BLOCKED n'est jamais gele)
awk -F'\t' '{print $1 "\t" $2 "\tFAIL"}' "$tmp/current.tsv" | sort -u >"$tmp/cur-fail.tsv"
: >"$tmp/new.tsv"
while IFS=$'\t' read -r app id st; do
  if [[ $st == BLOCKED ]]; then printf '%s\t%s\tBLOCKED\n' "$app" "$id" >>"$tmp/new.tsv"
  elif ! grep -qxF "$app"$'\t'"$id"$'\tFAIL' "$tmp/baseline.tsv"; then printf '%s\t%s\tFAIL\n' "$app" "$id" >>"$tmp/new.tsv"; fi
done <"$tmp/current.tsv"
# violations gelees disparues, pour les apps evaluees
: >"$tmp/gone.tsv"
for d in "${apps[@]}"; do
  n="$(basename "$d")"
  while IFS= read -r l; do grep -qxF "$l" "$tmp/cur-fail.tsv" || echo "$l" >>"$tmp/gone.tsv"; done < <(grep "^$n"$'\t' "$tmp/baseline.tsv" || true)
done

for d in "${apps[@]}"; do
  n="$(basename "$d")"
  echo "== app-test static $n ($d)"; cat "$tmp/out.$n"
done
if [[ -s $tmp/gone.tsv ]]; then echo "APP_TEST_RATCHET=TIGHTEN gone=$(wc -l <"$tmp/gone.tsv" | tr -d ' ') (lancer scripts/app-test-changed.sh --update)"; sed 's/^/  gone: /' "$tmp/gone.tsv"; fi
if [[ -s $tmp/new.tsv ]]; then
  echo "APP_TEST_CHANGED=FAIL new_violations=$(wc -l <"$tmp/new.tsv" | tr -d ' ') apps=${#apps[@]}" >&2
  awk -F'\t' '{print "  NEW " $1 " " $2 " " $3}' "$tmp/new.tsv" >&2
  echo "Corriger l'application ou declarer une exception justifiee dans app-test.yaml (jamais la baseline a la main)." >&2
  exit 1
fi
echo "APP_TEST_CHANGED=PASS apps=${#apps[@]} frozen=$(wc -l <"$tmp/cur-fail.tsv" | tr -d ' ')"
