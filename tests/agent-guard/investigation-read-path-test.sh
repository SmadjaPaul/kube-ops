#!/usr/bin/env bash
# Chemin de lecture unique des scripts d'investigation (aucun accès cluster).
# Usage : bash tests/agent-guard/investigation-read-path-test.sh
# Faux kubectl-ro.sh (KUBECTL_RO_SCRIPT) et faux kubectl sur le PATH : un appel direct à kubectl échoue.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
fails=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*" >&2; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/investigation-read-path.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export FAKE_LOG="$tmp/ro.log"
: >"$FAKE_LOG"

# kubectl direct = erreur franche
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "DIRECT_KUBECTL $*" >>"${FAKE_LOG:?}"
exit 99
SH
chmod +x "$tmp/bin/kubectl"

# faux kubectl-ro.sh : journalise les arguments, répond avec des fixtures
cat >"$tmp/kubectl-ro.sh" <<'SH'
#!/usr/bin/env bash
echo "RO $*" >>"${FAKE_LOG:?}"
case "$*" in
  "get application.argoproj.io -n argocd -o name")
    printf 'application.argoproj.io/apps-media\napplication.argoproj.io/infra-security\n' ;;
  "get application.argoproj.io apps-media -n argocd -o json")
    cat <<'JSON'
{"metadata":{"name":"apps-media"},"spec":{"project":"p","source":{"repoURL":"r","targetRevision":"main","path":"k8s"}},
 "status":{"sync":{"status":"Synced","revision":"abcdef1234"},"health":{"status":"Healthy"},
 "resources":[{"kind":"Deployment","namespace":"media","name":"a","status":"Synced","health":{"status":"Healthy"}}]}}
JSON
    ;;
  "get pods -n media -o json")
    echo '{"items":[{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  "get --raw "*) echo '{"data":{"result":[]}}' ;;
  *) : ;;
esac
SH
chmod +x "$tmp/kubectl-ro.sh"

run() { PATH="$tmp/bin:$PATH" KUBECTL_RO_SCRIPT="$tmp/kubectl-ro.sh" OUTPUT=summary "$@"; }

# status-app : résolution apps-<nom>, sortie sans bruit préflight, VERIFY=PASS
out=$(run bash scripts/status-app.sh media summary 2>"$tmp/err") || ko "status-app summary a échoué"
grep -q '^VERIFY=PASS$' <<<"$out" && ok "status-app résout media -> apps-media, VERIFY=PASS" || ko "status-app VERIFY=PASS absent : $out"
! grep -q 'KUBE_ACCESS' <<<"$out" && ok "status-app : stdout sans ligne KUBE_ACCESS" || ko "status-app : stdout pollué"
json=$(run bash scripts/status-app.sh media full) || ko "status-app full a échoué"
jq -e '.application == "apps-media"' <<<"$json" >/dev/null && ok "status-app full : stdout est du JSON pur" || ko "status-app full : JSON invalide"

# diagnose-app : lecture seule via le wrapper
run bash scripts/diagnose-app.sh media summary >"$tmp/diag.out" 2>&1 || ko "diagnose-app summary a échoué"
grep -q '^VERIFY=' "$tmp/diag.out" && ok "diagnose-app summary" || ko "diagnose-app : VERIFY absent"
run bash scripts/diagnose-app.sh media full >"$tmp/diag-full.out" 2>&1 || ko "diagnose-app full a échoué"
grep -q '=== NAMESPACE media ===' "$tmp/diag-full.out" && ok "diagnose-app full" || ko "diagnose-app full : namespace absent"

# application inconnue : échec net
! run bash scripts/status-app.sh nope summary >/dev/null 2>&1 && ok "status-app : application inconnue refusée" || ko "status-app : application inconnue acceptée"

! grep -q DIRECT_KUBECTL "$FAKE_LOG" && ok "aucun appel direct à kubectl" || ko "appel direct à kubectl : $(grep DIRECT_KUBECTL "$FAKE_LOG" | head -1)"

# observe.sh app : le nom Argo est apps-<app> ou infra-<app>, pas <app>
mkdir -p "$tmp/obs/lib"
cp scripts/observe.sh "$tmp/obs/observe.sh"
cp "$tmp/kubectl-ro.sh" "$tmp/obs/kubectl-ro.sh"
: >"$FAKE_LOG"
PATH="$tmp/bin:$PATH" bash "$tmp/obs/observe.sh" --local app media >"$tmp/obs.out" 2>&1 || ko "observe --local app a échoué"
argo_query=$(grep -m1 'argocd_app_info' "$FAKE_LOG" | python3 -c 'import sys,urllib.parse as u; print(u.unquote(sys.stdin.read()))' || true)
grep -q 'argocd_app_info{name=~"(app-|apps-|infra-)?media"}' <<<"$argo_query" &&
  ok "observe app : requête Argo apps-/infra-/nom nu" || ko "observe app : requête Argo inattendue : $argo_query"
! grep -q 'argocd_app_info{name="media"}' <<<"$argo_query" && ok "observe app : plus de nom exact" || ko "observe app : nom exact"

# investigate.sh : point d'entrée unique, faux kubectl-ro.sh + faux observe
cat >"$tmp/observe.sh" <<'SH'
#!/usr/bin/env bash
echo "OBSERVE $*" >>"${FAKE_LOG:?}"
[ "${OBSERVE_FAIL:-}" = 1 ] && { echo "observe: token absent" >&2; exit 2; }
echo "  homelab pods_running=1"
SH
run_inv() { PATH="$tmp/bin:$PATH" KUBECTL_RO_SCRIPT="$tmp/kubectl-ro.sh" OBSERVE_SCRIPT="$tmp/observe.sh" "$@"; }
: >"$FAKE_LOG"
inv=$(run_inv bash scripts/investigate.sh app media 2>"$tmp/inv.err") || ko "investigate app a échoué : $(cat "$tmp/inv.err")"
for marker in '=== ARGO ===' '=== WORKLOADS ===' '=== METRICS ===' 'pods_running=1' 'ARGO=Synced/Healthy' 'VERIFY=PASS' 'EVIDENCE_SCOPE=RUNTIME'; do
  grep -qF "$marker" <<<"$inv" && ok "investigate : $marker" || ko "investigate : $marker absent"
done
[ "$(grep -c '^VERIFY=' <<<"$inv")" = 1 ] && ok "investigate : un seul VERIFY=" || ko "investigate : VERIFY= multiple"
ev=$(sed -n 's/^EVIDENCE=//p' <<<"$inv")
[ -s "$ev" ] && [ "$(stat -f %Lp "$ev" 2>/dev/null || stat -c %a "$ev")" = 600 ] && ok "investigate : EVIDENCE privé 0600" || ko "investigate : EVIDENCE absent ou non 0600"
grep -q '^OBSERVE app media$' "$FAKE_LOG" && ok "investigate : observe app media appelé" || ko "investigate : observe non appelé"
! grep -q DIRECT_KUBECTL "$FAKE_LOG" && ok "investigate : aucun kubectl direct" || ko "investigate : kubectl direct"
# métriques indisponibles : non bloquant
inv2=$(OBSERVE_FAIL=1 run_inv bash scripts/investigate.sh app apps-media 2>/dev/null) && ok "investigate : métriques absentes sans échec" || ko "investigate : métriques absentes font échouer"
grep -q 'METRICS=UNAVAILABLE' <<<"$inv2" && grep -q '^VERIFY=PASS$' <<<"$inv2" && ok "investigate : METRICS=UNAVAILABLE, VERIFY inchangé" || ko "investigate : METRICS=UNAVAILABLE absent"
# cluster : transmis à kubectl-ro.sh
: >"$FAKE_LOG"
run_inv bash scripts/investigate.sh app media --cluster oracle-a1 >/dev/null 2>&1 || true
grep -q '^RO --cluster oracle-a1 get ' "$FAKE_LOG" && ok "investigate : --cluster transmis" || ko "investigate : --cluster non transmis"
! run_inv bash scripts/investigate.sh app media --cluster nope >/dev/null 2>&1 && ok "investigate : cluster inconnu refusé" || ko "investigate : cluster inconnu accepté"
! run_inv bash scripts/investigate.sh app nope >/dev/null 2>&1 && ok "investigate : application inconnue -> échec" || ko "investigate : application inconnue acceptée"
! run_inv bash scripts/investigate.sh pods media >/dev/null 2>&1 && ok "investigate : sous-commande inconnue refusée" || ko "investigate : sous-commande inconnue acceptée"

# Garde : aucun script d'investigation n'appelle kubectl directement (lecture via kubectl-ro.sh).
# Exception documentée : .agents/skills/cilium-hubble/scripts/hubble-check.sh ouvre un
# `kubectl port-forward` (verbe hors liste blanche de kubectl-ro.sh, ne lit aucune ressource).
INVESTIGATION_SCRIPTS=(
  scripts/investigate.sh scripts/status-app.sh scripts/diagnose-app.sh scripts/observe.sh
  scripts/runtime-inventory.sh scripts/runtime-smoke.sh scripts/cluster-reality.sh scripts/backup-audit.sh
  scripts/lib/argo-app.sh scripts/lib/kube-read.sh
)
for f in "${INVESTIGATION_SCRIPTS[@]}"; do
  if grep -nE '(^|[^-/.[:alnum:]_])kubectl( |$)' "$f" | grep -vE '^[0-9]+:\s*#' | grep -q .; then
    ko "$f appelle kubectl directement"
  else
    ok "$f : lecture par kubectl-ro.sh seulement"
  fi
  grep -q 'kube-preflight.sh' "$f" && ko "$f source kube-preflight.sh (le préflight appartient à kubectl-ro.sh)" || true
done
# hubble-check : seule exception, et seulement pour port-forward
hc_direct=$(grep -nE '(^|[^-/.[:alnum:]_])kubectl( |$)' .agents/skills/cilium-hubble/scripts/hubble-check.sh | grep -vE '^[0-9]+:\s*#|command -v' || true)
if [ -n "$hc_direct" ] && ! grep -v 'port-forward' <<<"$hc_direct" | grep -q .; then
  ok "hubble-check : kubectl limité à port-forward"
else
  ko "hubble-check : appel kubectl autre que port-forward : $hc_direct"
fi

# hubble-check : préflight obligatoire
hc=.agents/skills/cilium-hubble/scripts/hubble-check.sh
grep -q 'lib/kube-preflight.sh' "$hc" && grep -q 'require_kube_access' "$hc" && ok "hubble-check : préflight" || ko "hubble-check sans préflight"
check "hubble-check : syntaxe" bash -n "$hc"
! bash "$hc" 'bad ns' >/dev/null 2>&1 && ok "hubble-check : namespace invalide refusé" || ko "hubble-check : namespace invalide accepté"

[ "$fails" -eq 0 ] || { echo "$fails échec(s)" >&2; exit 1; }
echo "INVESTIGATION_READ_PATH_TEST=PASS"
