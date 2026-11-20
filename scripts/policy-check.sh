#!/usr/bin/env bash
# Etape Kyverno du gate statique : rend les racines Kustomize actives, applique les
# ValidatingPolicy (platform-baseline.yaml + policy/static/repo-contract.yaml) avec
# `kyverno apply`, puis compare les violations a policy/baseline.tsv (cliquet).
#
#   scripts/policy-check.sh            echec sur toute violation NOUVELLE ; signale celles disparues
#   scripts/policy-check.sh --update   reecrit policy/baseline.tsv (rendu complet seulement)
#   scripts/policy-check.sh --tests    kyverno test des politiques + cas a jour (sans rendu)
#
# Environnement : V1_CONTRACT_ROOTS (liste separee par des virgules, comme check-v1-active-contract.sh ;
# defaut `all` = tableau roots de ce script). KYVERNO_CONTEXT_FILE (optionnel) est passe a
# --context-file pour les politiques qui liraient des objets du cluster (aucune a ce jour :
# le namespace est lu sur la ressource elle-meme). Aucun acces cluster ; aucune valeur de Secret
# n'est lue : seules les lignes "policy ... resource ... failed" de la CLI sont conservees.
set -euo pipefail

cd "$(dirname "$0")/.."
export LC_ALL=C

POLICIES=(k8s/infrastructure/security/policies/platform-baseline.yaml policy/static/repo-contract.yaml)
BASELINE=policy/baseline.tsv
mode=check
case "${1:-}" in
  "") ;;
  --update) mode=update ;;
  --tests) mode=tests ;;
  *) echo "usage: $0 [--update|--tests]" >&2; exit 2 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "POLICY_CHECK=BLOCKED missing_tool=$1" >&2; exit 2; }; }
need kyverno

if [[ $mode == tests ]]; then
  python3 -I tests/policies/gen-tests.py --check
  log="$(mktemp "${TMPDIR:-/tmp}/policy-tests.XXXXXX")"
  trap 'rm -f "$log"' EXIT
  kyverno test tests/policies --remove-color >"$log" 2>&1 || true
  grep -E 'Test Summary|Error' "$log" || true
  grep -q 'Test Summary: [0-9]* tests passed and 0 tests failed' "$log" || { echo "POLICY_TESTS=FAIL" >&2; exit 1; }
  echo "POLICY_TESTS=PASS"
  exit 0
fi

need kustomize
need helm
started=$(date +%s)
work="$(mktemp -d "${TMPDIR:-/tmp}/policy-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

requested="${V1_CONTRACT_ROOTS:-all}"
roots=()
if [[ $requested == all ]]; then
  while IFS= read -r r; do roots+=("$r"); done < <(awk '/^roots=\(/{f=1;next} f&&/^\)/{exit} f{print $1}' scripts/check-v1-active-contract.sh)
  ((${#roots[@]} > 0)) || { echo "POLICY_CHECK=BLOCKED reason=no_roots_found" >&2; exit 2; }
else
  [[ $mode == update ]] && { echo "ERROR: --update exige le rendu complet (V1_CONTRACT_ROOTS non defini)" >&2; exit 2; }
  IFS=',' read -r -a roots <<<"$requested"
fi

# Rendu partage et parallele (scripts/lib/render-cache.sh, meme cache que v1-contract et
# backup-contract) ; un echec de rendu echoue l'etape.
for root in "${roots[@]}"; do
  [[ -f "$root/kustomization.yaml" || -f "$root/kustomization.yml" ]] || { echo "POLICY_CHECK=FAIL no_kustomization root=$root" >&2; exit 1; }
done
bash scripts/lib/render-cache.sh prerender "${roots[@]}" || { echo "POLICY_CHECK=FAIL render_failed" >&2; exit 1; }
files=()
for root in "${roots[@]}"; do
  files+=("$(bash scripts/lib/render-cache.sh render "$root")") || { echo "POLICY_CHECK=FAIL render_failed root=$root" >&2; exit 1; }
done
i=${#files[@]}

args=()
for ((j = 0; j < i; j++)); do args+=(--resource "${files[j]}"); done
ctx=()
[[ -n "${KYVERNO_CONTEXT_FILE:-}" ]] && ctx=(--context-file "$KYVERNO_CONTEXT_FILE")
# kyverno sort en 0 meme avec des violations (pas de --audit-warn) ; on lit le resultat sur stdout.
kyverno apply "${POLICIES[@]}" "${args[@]}" ${ctx[@]+"${ctx[@]}"} --remove-color >"$work/out.txt" 2>"$work/err.txt" || true

summary="$(grep -E '^pass: [0-9]+, fail: [0-9]+' "$work/out.txt" || true)"
[[ -n "$summary" ]] || { echo "POLICY_CHECK=FAIL kyverno_no_summary" >&2; { grep -hiE 'error|duplicate' "$work/out.txt" "$work/err.txt" || true; } | cut -c1-300 | head -5 >&2; exit 1; }
errors="$(sed -E 's/.*error: ([0-9]+).*/\1/' <<<"$summary")"
loaded="$(sed -nE 's/^Applying ([0-9]+) policy rule.*/\1/p' "$work/out.txt" | head -1)"
((${loaded:-0} > 0)) || { echo "POLICY_CHECK=FAIL no_policy_loaded" >&2; grep -E 'ERROR|Error' "$work/err.txt" "$work/out.txt" | cut -c1-300 | head -5 >&2; exit 1; }
((errors == 0)) || { echo "POLICY_CHECK=FAIL kyverno_errors=$errors" >&2; grep -E '^policy .* error' "$work/out.txt" | cut -c1-300 | head -10 >&2; exit 1; }

# "policy <nom> -> resource <ns>/<Kind>/<nom> failed:" -> "<regle>\t<ns>/<Kind>/<nom>"
sed -nE 's/^policy ([^ ]+) -> resource ([^ ]+) failed:.*/\1\t\2/p' "$work/out.txt" | sort -u >"$work/current.tsv"

# Regle inter-ressources (non exprimable en politique par objet) : tout namespace applicatif qui
# porte des workloads doit porter au moins une CiliumNetworkPolicy dans le rendu (default-deny,
# k8s/CLAUDE.md). Evaluee sur l'union des racines, donc seulement sur le rendu complet : une CNP
# peut vivre dans une autre racine que le workload.
if [[ $requested == all ]]; then
  need yq
  sys_ns='gatekeeper-system|kube-node-lease|kube-public|kube-system|kubearmor|kyverno|monitoring|security-system'
  for ((j = 0; j < i; j++)); do
    yq eval-all 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "CronJob") | .metadata.namespace' "${files[j]}"
  done | grep -vE '^(---|null)$|^$' | grep -vE "^($sys_ns)$" | sort -u >"$work/ns-workloads.txt"
  for ((j = 0; j < i; j++)); do
    yq eval-all 'select(.kind == "CiliumNetworkPolicy") | .metadata.namespace' "${files[j]}"
  done | grep -vE '^(---|null)$|^$' | sort -u >"$work/ns-cnp.txt"
  comm -23 "$work/ns-workloads.txt" "$work/ns-cnp.txt" | sed 's/.*/repo-contract-cnp-per-namespace\t&/' >>"$work/current.tsv"
  sort -u -o "$work/current.tsv" "$work/current.tsv"
else
  echo "POLICY_CNP=SKIPPED (contrôle CiliumNetworkPolicy par namespace : rendu complet seulement)"
fi

if [[ $mode == update ]]; then
  {
    echo "# Baseline du cliquet Kyverno (scripts/policy-check.sh). Une ligne = une violation existante : <politique><TAB><ns>/<Kind>/<nom>."
    echo "# Ne jamais ajouter de ligne a la main pour faire passer une PR : corriger le manifeste. Resserrer avec : just policy-baseline-update."
    cat "$work/current.tsv"
  } >"$BASELINE"
  echo "POLICY_BASELINE=UPDATED violations=$(wc -l <"$work/current.tsv" | tr -d ' ')"
  exit 0
fi

grep -vE '^#|^$' "$BASELINE" | sort -u >"$work/baseline.tsv"
comm -13 "$work/baseline.tsv" "$work/current.tsv" >"$work/new.tsv"
comm -23 "$work/baseline.tsv" "$work/current.tsv" >"$work/gone.tsv"

if [[ $requested == all ]]; then
  if [[ -s "$work/gone.tsv" ]]; then
    echo "POLICY_RATCHET=TIGHTEN gone=$(wc -l <"$work/gone.tsv" | tr -d ' ') (violations corrigees : lancer just policy-baseline-update)"
    sed 's/^/  gone: /' "$work/gone.tsv" | head -20
  fi
else
  echo "POLICY_RATCHET=PARTIAL roots=${#roots[@]} (les violations disparues ne sont evaluees que sur le rendu complet)"
fi

elapsed=$(($(date +%s) - started))
if [[ -s "$work/new.tsv" ]]; then
  echo "POLICY_CHECK=FAIL new_violations=$(wc -l <"$work/new.tsv" | tr -d ' ') duration_seconds=$elapsed" >&2
  awk -F'\t' '{print "  NEW " $1 " -> " $2}' "$work/new.tsv" >&2
  echo "Corriger le manifeste (regle dans k8s/CLAUDE.md). Le message de chaque regle : grep -A1 'name: <politique>' des fichiers de politique." >&2
  exit 1
fi
echo "POLICY_CHECK=PASS violations=$(wc -l <"$work/current.tsv" | tr -d ' ') baseline=$(wc -l <"$work/baseline.tsv" | tr -d ' ') roots=${#roots[@]} duration_seconds=$elapsed"
