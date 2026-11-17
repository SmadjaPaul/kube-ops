#!/usr/bin/env bash
# Acceptation de la baseline oracle-a1 APRES la reconstruction (VCN-native + Cilium chaining).
#
#   acceptance.sh --dry   : aucun cluster. Syntaxe, liste des controles, auto-verification
#                           (le script ne lit aucun Secret). Seul mode execute en CI.
#   acceptance.sh         : controles sur le cluster du contexte kubectl courant.
#
# Ce que le script fait : lectures (get) et dry-run serveur d'admission, plus UN pod
# ephemere (namespace backstage, restreint, sans token, supprime en sortie) pour les tests
# reseau. Il ne detruit rien d'autre et ne lit ni n'affiche aucun Secret.
#
# Controles :
#   1 Cilium : DaemonSet cilium Ready sur tous les noeuds, operator disponible.
#   2 default-deny : NetworkPolicy default-deny presente dans auth, backstage, hindsight,
#     databases ; effet : depuis un pod backstage, un egress non liste (https://example.com
#     et l'API server) echoue.
#   3 IMDS : depuis ce pod NON privilegie, curl --max-time 3 http://169.254.169.254/ doit
#     echouer. Hors couverture, documente : un pod hostNetwork (ex. csi-oci-node, exempte
#     dans kube-system) partage la pile reseau du noeud et atteint l'IMDS ; il n'est pas
#     teste ici, la VAP le refuse dans les namespaces applicatifs (controle 5).
#   4 Quotas : ResourceQuota compute de chaque namespace egale a expected-quotas.tsv.
#   5 VAP : un pod privilegie et un pod hostNetwork sont refuses (dry-run=server, namespace
#     databases : PSA n'y est qu'en warn, donc le refus vient bien de la VAP).
#   6 DNS : le nom du service API se resout depuis le pod de test (egress DNS autorise).
#
# Variables : ACCEPTANCE_IMAGE (image avec sh, sleep et curl ; defaut curlimages/curl, a
# epingler par digest dans un runbook), ACCEPTANCE_NS (defaut backstage), KUBECTL.
# Code de sortie : 0 si tout passe, 1 sinon, 2 si un prerequis manque.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/tests/oke-baseline"
KUBECTL="${KUBECTL:-kubectl}"
NS="${ACCEPTANCE_NS:-backstage}"
IMAGE="${ACCEPTANCE_IMAGE:-docker.io/curlimages/curl:8.11.1}"
POD="acceptance-$$"
fails=0
pod_created=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
k() { "$KUBECTL" "$@"; }

cleanup() {
  if [[ "$pod_created" -eq 1 ]]; then
    k -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

list_checks() {
  cat <<'LIST'
1 cilium-ready        DaemonSet cilium Ready, operator disponible
2 default-deny        NetworkPolicy default-deny x4 + egress non liste bloque depuis un pod
3 imds-blocked        curl --max-time 3 http://169.254.169.254/ echoue (pod non privilegie)
4 quotas              ResourceQuota compute == expected-quotas.tsv
5 vap-denies          pod privilegie et pod hostNetwork refuses (dry-run=server)
6 dns                 resolution DNS depuis le pod de test
LIST
}

selftest() {
  # Aucune lecture de Secret : le script ne doit jamais appeler get/describe secret.
  if grep -nE '(get|describe|view-secret)[[:space:]]+(-n[[:space:]]+[^[:space:]]+[[:space:]]+)?secrets?([[:space:]]|$)' "${BASH_SOURCE[0]}" | grep -v 'grep -nE' | grep -v '^[0-9]*:[[:space:]]*#'; then
    echo "FAIL: le script lit des Secrets"; return 1
  fi
  [[ -r "$here/expected-quotas.tsv" ]] || { echo "FAIL: expected-quotas.tsv absent"; return 1; }
  [[ -r "$here/fixtures/pod-privileged.yaml" && -r "$here/fixtures/pod-hostnetwork.yaml" ]] || { echo "FAIL: fixtures VAP absentes"; return 1; }
  echo "SELFTEST=PASS"
}

check_cilium() {
  local want ready
  want="$(k -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  ready="$(k -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  if [[ -n "$want" && "$want" -gt 0 && "$want" == "$ready" ]]; then pass "cilium agents Ready ($ready/$want)"; else fail "cilium agents Ready (ready=${ready:-?} desired=${want:-?})"; fi
  local avail
  avail="$(k -n kube-system get deploy cilium-operator -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [[ -n "$avail" && "$avail" -ge 1 ]]; then pass "cilium-operator disponible"; else fail "cilium-operator disponible"; fi
}

check_default_deny_objects() {
  local ns
  for ns in auth backstage hindsight databases; do
    if k -n "$ns" get networkpolicy default-deny >/dev/null 2>&1; then pass "NetworkPolicy default-deny presente ($ns)"; else fail "NetworkPolicy default-deny presente ($ns)"; fi
  done
  if k get ciliumclusterwidenetworkpolicy deny-imds >/dev/null 2>&1; then pass "CCNP deny-imds presente"; else fail "CCNP deny-imds presente"; fi
}

check_quotas() {
  local ns rcpu rmem lmem pods got
  while IFS=$'\t' read -r ns rcpu rmem lmem pods; do
    [[ -z "$ns" || "$ns" == \#* ]] && continue
    got="$(k -n "$ns" get resourcequota compute -o jsonpath='{.spec.hard.requests\.cpu}{"\t"}{.spec.hard.requests\.memory}{"\t"}{.spec.hard.limits\.memory}{"\t"}{.spec.hard.pods}' 2>/dev/null)"
    if [[ "$got" == "$rcpu"$'\t'"$rmem"$'\t'"$lmem"$'\t'"$pods" ]]; then pass "quota $ns ($rcpu, $rmem, $lmem, $pods pods)"; else fail "quota $ns (attendu $rcpu/$rmem/$lmem/$pods ; lu ${got//$'\t'/\/})"; fi
  done < "$here/expected-quotas.tsv"
}

check_vap() {
  local f out rc
  for f in pod-privileged pod-hostnetwork; do
    rc=0
    out="$(sed 's/namespace: backstage/namespace: databases/' "$here/fixtures/$f.yaml" | k apply --dry-run=server -f - 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q 'baseline-pod-hardening' <<<"$out"; then pass "VAP refuse $f"; else fail "VAP refuse $f"; fi
  done
}

start_pod() {
  if ! k -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS, labels: {app.kubernetes.io/name: oke-acceptance}}
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext: {runAsNonRoot: true, runAsUser: 100, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMAGE
      command: [sleep, "300"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
YAML
  then
    return 1
  fi
  pod_created=1
  k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1
}

in_pod() { k -n "$NS" exec "$POD" -c c -- "$@" 2>/dev/null; }

check_network() {
  if ! start_pod; then
    fail "pod de test demarre dans $NS (reseau non teste)"
    return
  fi
  local rc
  # curl : 6 = resolution impossible, 28 = timeout, 7 = connexion refusee ; 0 = joignable.
  rc=0; in_pod curl -sS --max-time 3 -o /dev/null http://169.254.169.254/ || rc=$?
  if [[ "$rc" -ne 0 ]]; then pass "IMDS injoignable depuis un pod non privilegie (curl rc=$rc)"; else fail "IMDS JOIGNABLE depuis un pod non privilegie"; fi
  rc=0; in_pod curl -sS --max-time 3 -o /dev/null https://example.com/ || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 6 ]]; then pass "egress non liste bloque (example.com, rc=$rc)"; else fail "egress non liste bloque (rc=$rc ; 0 = joignable, 6 = DNS casse)"; fi
  rc=0; in_pod curl -sS --max-time 3 -o /dev/null https://kubernetes.default.svc.cluster.local/ || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 6 ]]; then pass "API server non joignable depuis backstage (rc=$rc), resolution OK"; else fail "API server depuis backstage (rc=$rc)"; fi
  rc=0; in_pod curl -sS --max-time 3 -o /dev/null http://kubernetes.default.svc.cluster.local/ || rc=$?
  if [[ "$rc" -ne 6 ]]; then pass "DNS : kubernetes.default.svc.cluster.local se resout"; else fail "DNS : resolution impossible depuis le pod de test"; fi
}

case "${1:-}" in
  --dry)
    list_checks
    selftest
    exit $?
    ;;
  "") ;;
  *) echo "usage: $0 [--dry]" >&2; exit 2 ;;
esac

command -v "$KUBECTL" >/dev/null || { echo "FAIL: kubectl requis" >&2; exit 2; }
selftest || exit 2
k version --request-timeout=10s >/dev/null 2>&1 || { echo "FAIL: cluster injoignable (contexte kubectl courant)" >&2; exit 2; }

check_cilium
check_default_deny_objects
check_quotas
check_vap
check_network

echo "ACCEPTANCE=$([[ $fails -eq 0 ]] && echo PASS || echo FAIL) fails=$fails"
[[ $fails -eq 0 ]]
