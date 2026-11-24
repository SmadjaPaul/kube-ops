#!/usr/bin/env bash
# Acceptation de la baseline reseau d'OKE (oracle-a1, PLT-384) : Cilium en chaining + CCNP IMDS.
#
#   acceptance.sh --dry   : aucun cluster. Liste des controles et auto-verification. Mode de la CI.
#   acceptance.sh         : controles sur oracle-a1, en LECTURE SEULE (get et logs via
#                           scripts/kubectl-ro.sh --cluster oracle-a1 par defaut). Aucun pod cree, aucun
#                           Secret lu : la preuve reseau vient de la sonde continue baseline-probe
#                           (CronJob de k8s/clusters/oracle-a1/baseline/probe.yaml, pod non privilegie).
#
# Controles :
#   1 argo           Applications infra-cilium et infra-baseline Synced/Healthy
#   2 cilium         DaemonSet cilium Ready sur tous les noeuds, cilium-operator disponible
#   3 policies       CCNP deny-imds et allow-egress-unisolated presentes ; NetworkPolicy default-deny (whoami)
#   4 quotas         ResourceQuota compute == expected-quotas.tsv
#   5 probe          dernier pod de la sonde : Succeeded et BASELINE_PROBE=PASS (IMDS 80/443 refuse,
#                    whoami joignable)
#   6 endpoints      (avertissement) pods hors kube-system sans CiliumEndpoint : demarres avant Cilium,
#                    donc hors politiques jusqu'a leur redemarrage
#
# Variable : KUBECTL (commande kubectl en lecture, defaut "bash scripts/kubectl-ro.sh --cluster oracle-a1").
# Code de sortie : 0 si tout passe, 1 sinon, 2 si un prerequis manque.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/tests/oke-baseline"
read -r -a KC <<<"${KUBECTL:-bash $root/scripts/kubectl-ro.sh --cluster oracle-a1}"
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
warn() { echo "WARN: $1"; }
k() { "${KC[@]}" "$@"; }

list_checks() {
  sed -n '/^# Controles :/,/^# Variable/p' "${BASH_SOURCE[0]}" | sed -e '1d' -e '$d' -e '/^#$/d' -e 's/^#   //'
}

selftest() {
  # Lecture seule : aucun verbe d'ecriture ni lecture de Secret dans les appels k().
  if grep -nE '^[^#]*\bk (apply|create|delete|patch|edit|exec|run|label|annotate|scale|rollout)\b' "${BASH_SOURCE[0]}"; then
    echo "FAIL: le script ecrit sur le cluster"; return 1
  fi
  if grep -nE '^[^#]*\bk (get|describe) [^|]*\bsecrets?\b' "${BASH_SOURCE[0]}"; then
    echo "FAIL: le script lit des Secrets"; return 1
  fi
  [[ -r "$here/expected-quotas.tsv" ]] || { echo "FAIL: expected-quotas.tsv absent"; return 1; }
  echo "SELFTEST=PASS"
}

check_argo() {
  local app st
  for app in infra-cilium infra-baseline; do
    st="$(k get -n argocd application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
    if [[ "$st" == "Synced/Healthy" ]]; then pass "Argo $app Synced/Healthy"; else fail "Argo $app (lu: ${st:-absente})"; fi
  done
}

check_cilium() {
  local want ready avail
  want="$(k get -n kube-system ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  ready="$(k get -n kube-system ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  if [[ -n "$want" && "$want" -gt 0 && "$want" == "$ready" ]]; then pass "cilium agents Ready ($ready/$want)"; else fail "cilium agents Ready (ready=${ready:-?} desired=${want:-?})"; fi
  avail="$(k get -n kube-system deploy cilium-operator -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [[ -n "$avail" && "$avail" -ge 1 ]]; then pass "cilium-operator disponible ($avail)"; else fail "cilium-operator disponible"; fi
}

check_policies() {
  local p
  for p in deny-imds allow-egress-unisolated; do
    if k get ciliumclusterwidenetworkpolicy "$p" -o name >/dev/null 2>&1; then pass "CCNP $p presente"; else fail "CCNP $p presente"; fi
  done
  if k get -n whoami networkpolicy default-deny -o name >/dev/null 2>&1; then pass "NetworkPolicy default-deny (whoami)"; else fail "NetworkPolicy default-deny (whoami)"; fi
}

check_quotas() {
  local ns rcpu rmem lmem pods got
  while IFS=$'\t' read -r ns rcpu rmem lmem pods; do
    [[ -z "$ns" || "$ns" == \#* ]] && continue
    got="$(k get -n "$ns" resourcequota compute -o jsonpath='{.spec.hard.requests\.cpu}{"/"}{.spec.hard.requests\.memory}{"/"}{.spec.hard.limits\.memory}{"/"}{.spec.hard.pods}' 2>/dev/null)"
    if [[ "$got" == "$rcpu/$rmem/$lmem/$pods" ]]; then pass "quota $ns ($got)"; else fail "quota $ns (attendu $rcpu/$rmem/$lmem/$pods ; lu ${got:-absent})"; fi
  done <"$here/expected-quotas.tsv"
}

check_probe() {
  local pod phase out
  pod="$(k get -n baseline-probe pods -l app.kubernetes.io/name=baseline-probe --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1)"
  if [[ -z "$pod" ]]; then fail "sonde : aucun pod baseline-probe (CronJob */15 : attendre le prochain passage)"; return; fi
  phase="$(k get -n baseline-probe "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
  out="$(k logs -n baseline-probe "$pod" --tail=20 2>/dev/null)"
  printf '%s\n' "$out" | sed 's/^/  probe| /'
  if [[ "$phase" == Succeeded ]] && grep -qx 'BASELINE_PROBE=PASS' <<<"$out"; then
    pass "sonde $pod : IMDS 80/443 refuse, whoami joignable"
  else
    fail "sonde $pod (phase=${phase:-?})"
  fi
}

check_endpoints() {
  local pods ceps missing=""
  pods="$(k get pods -A --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.hostNetwork}{"\n"}{end}' 2>/dev/null | awk '$2 != "true" {print $1}' | grep -v '^kube-system/')"
  if [[ -z "$pods" ]]; then fail "endpoints : liste des pods illisible"; return; fi
  ceps="$(k get ciliumendpoints -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  while read -r p; do
    [[ -z "$p" ]] && continue
    grep -qxF "$p" <<<"$ceps" || missing+=" $p"
  done <<<"$pods"
  if [[ -z "$missing" ]]; then pass "tous les pods (hors kube-system, hors hostNetwork) sont des endpoints Cilium"
  else warn "pods hors politiques Cilium jusqu'a leur redemarrage :$missing"; fi
}

case "${1:-}" in
  --dry) list_checks; selftest; exit $? ;;
  "") ;;
  *) echo "usage: $0 [--dry]" >&2; exit 2 ;;
esac

selftest || exit 2
k version >/dev/null 2>&1 || { echo "FAIL: oracle-a1 injoignable (NetBird / jeton agent-operator)" >&2; exit 2; }

check_argo
check_cilium
check_policies
check_quotas
check_probe
check_endpoints

echo "ACCEPTANCE=$([[ $fails -eq 0 ]] && echo PASS || echo FAIL) fails=$fails"
[[ $fails -eq 0 ]]
