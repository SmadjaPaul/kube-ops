#!/usr/bin/env bash
# shellcheck disable=SC2015 # res() retourne toujours 0 : A && res PASS || res FAIL est sur.
# Correctif C1 (oracle-a1) : allow-egress-unisolated exclut les namespaces
# platform.smadja.dev/egress-isolated=true ; deny-imds reste global.
#
# Usage (operateur avec un kubeconfig OKE explicite, jamais ~/.kube/config) :
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh plan      # lecture seule
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh backup    # sauvegarde des CCNP vivantes
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh apply     # kubectl diff puis apply -f imds-deny.yaml
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh test      # sondes ephemeres
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh rollback  # reapplique la sauvegarde, mesure la duree
#   KUBECONFIG=<oke> bash tests/oke-baseline/c1-egress-isolation.sh all       # plan, backup, test (avant), apply, test (apres)
# Variables : ISO_NS (namespace isole sonde, defaut openchoreo-control-plane),
#             BACKUP_DIR (defaut ./c1-backup), PROBE_IMAGE.
# Sortie : 0 si aucun FAIL ; les sondes et le namespace temoin sont supprimes a la sortie.
set -euo pipefail

: "${KUBECONFIG:?KUBECONFIG explicite requis (cluster oracle-a1)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KDIR="$ROOT/k8s/clusters/oracle-a1/baseline"
ISO_NS="${ISO_NS:-openchoreo-control-plane}"
CTRL_NS="c1-probe-open"
POD="c1-netprobe"
BACKUP_DIR="${BACKUP_DIR:-$PWD/c1-backup}"
LABEL="platform.smadja.dev/egress-isolated"
SEL_KEY="io.cilium.k8s.namespace.labels.$LABEL"
PROBE_IMAGE="${PROBE_IMAGE:-docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40}"
FAILS=0

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
res() { log "$1 $2 : $3"; [[ "$1" != FAIL ]] || FAILS=$((FAILS + 1)); }

guard() {
  kubectl get ciliumclusterwidenetworkpolicy allow-egress-unisolated deny-imds -o name >/dev/null \
    || { echo "CCNP allow-egress-unisolated/deny-imds absentes : mauvais cluster ?" >&2; exit 2; }
}

plan() {
  log "== Selecteur vivant allow-egress-unisolated"
  kubectl get ciliumclusterwidenetworkpolicy allow-egress-unisolated -o json | jq -c '.spec.endpointSelector'
  log "== Namespaces EXCLUS par le correctif (label $LABEL=true ; hors auth/hindsight/databases deja exclus)"
  kubectl get ns -l "$LABEL=true" -o json \
    | jq -r '.items[].metadata.name | select(IN("auth","backstage","hindsight","databases") | not)'
  log "== Pods concernes"
  for ns in $(kubectl get ns -l "$LABEL=true" -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n "$ns" get pods --no-headers -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,PHASE:.status.phase 2>/dev/null || true
  done
  log "== Namespaces dp-* SANS le label (restent ouverts par l'allow-all)"
  kubectl get ns -o json | jq -r --arg l "$LABEL" \
    '.items[] | select(.metadata.name | startswith("dp-")) | select(.metadata.labels[$l] != "true") | .metadata.name'
}

backup() {
  mkdir -p "$BACKUP_DIR"
  kubectl get ciliumclusterwidenetworkpolicy allow-egress-unisolated deny-imds -o yaml > "$BACKUP_DIR/ccnp-live.yaml"
  # Copie reappliquable : sans resourceVersion/uid/managedFields/status.
  kubectl get ciliumclusterwidenetworkpolicy allow-egress-unisolated deny-imds -o json \
    | jq '.items |= map(del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
            .metadata.generation, .metadata.managedFields, .status))' > "$BACKUP_DIR/ccnp-restore.json"
  sha256sum "$BACKUP_DIR"/ccnp-* 2>/dev/null || shasum -a 256 "$BACKUP_DIR"/ccnp-*
  log "sauvegarde : $BACKUP_DIR"
}

apply_fix() {
  [[ -s "$BACKUP_DIR/ccnp-restore.json" ]] || { echo "lancer 'backup' d'abord" >&2; exit 2; }
  kubectl diff -f "$KDIR/imds-deny.yaml" || true
  kubectl apply -f "$KDIR/imds-deny.yaml"
  kubectl get ciliumclusterwidenetworkpolicy allow-egress-unisolated -o json \
    | jq -e --arg k "$SEL_KEY" '.spec.endpointSelector.matchExpressions | any(.key == $k and .operator == "NotIn" and .values == ["true"])' >/dev/null \
    && res PASS S-applied "selecteur vivant contient $SEL_KEY NotIn [true]" \
    || res FAIL S-applied "selecteur vivant sans l'exclusion"
  kubectl get ciliumclusterwidenetworkpolicy deny-imds -o json | jq -e '.spec.endpointSelector == {}' >/dev/null \
    && res PASS S-imds-global "deny-imds selectionne tous les endpoints" \
    || res FAIL S-imds-global "deny-imds n'est plus global"
}

rollback() {
  [[ -s "$BACKUP_DIR/ccnp-restore.json" ]] || { echo "aucune sauvegarde dans $BACKUP_DIR" >&2; exit 2; }
  local t0 t1
  t0=$(date +%s)
  kubectl replace -f "$BACKUP_DIR/ccnp-restore.json"
  ensure_probes
  # Retour effectif = l'egress Internet du namespace isole redevient ouvert (etat d'avant).
  if wait_class "$ISO_NS" OPEN https://1.1.1.1/; then
    t1=$(date +%s); res PASS S-rollback "CCNP originales reappliquees, egress $ISO_NS reouvert en $((t1 - t0)) s"
  else
    res FAIL S-rollback "egress $ISO_NS non reouvert 90 s apres replace"
  fi
}

cleanup() {
  kubectl -n "$ISO_NS" delete pod "$POD" --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "$CTRL_NS" --wait=true --timeout=120s >/dev/null 2>&1 || true
  if kubectl get namespace "$CTRL_NS" >/dev/null 2>&1; then res FAIL S-cleanup "namespace $CTRL_NS encore present"; fi
}

probe_pod() { # NS
  kubectl -n "$1" get pod "$POD" >/dev/null 2>&1 && return 0
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $1, labels: {app.kubernetes.io/name: c1-netprobe}}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  hostNetwork: false
  securityContext: {runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, seccompProfile: {type: RuntimeDefault}}
  volumes:
    - name: ca
      configMap: {name: kube-root-ca.crt}
  containers:
    - name: probe
      image: $PROBE_IMAGE
      command: ["sleep", "600"]
      volumeMounts: [{name: ca, mountPath: /ca, readOnly: true}]
      resources: {requests: {cpu: 5m, memory: 16Mi}, limits: {cpu: 100m, memory: 32Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
  kubectl -n "$1" wait --for=condition=Ready --timeout=180s "pod/$POD" >/dev/null
}

ensure_probes() {
  trap cleanup EXIT INT TERM
  kubectl get ns "$CTRL_NS" >/dev/null 2>&1 || kubectl create namespace "$CTRL_NS" --dry-run=client -o yaml \
    | kubectl label --local -f - -o yaml pod-security.kubernetes.io/enforce=restricted | kubectl apply -f - >/dev/null
  probe_pod "$ISO_NS"
  probe_pod "$CTRL_NS"
}

# rc curl -> classe TCP. 28 = timeout de connexion (refus Cilium = paquets jetes).
classify() { case "$1" in 0) echo OPEN;; 28) echo TIMEOUT;; 7) echo REFUSED;; 6) echo DNS-FAIL;; 35|51|58|60) echo TLS-ERROR;; *) echo "OTHER($1)";; esac; }
probe() { # NS URL [args] -> classe
  local ns="$1" rc=0; shift
  kubectl -n "$ns" exec "$POD" -- curl -sS -o /dev/null --connect-timeout 5 -m 8 "$@" >/dev/null 2>&1 || rc=$?
  classify "$rc"
}
wait_class() { # NS CLASSE URL [args] : attend la propagation Cilium (90 s max)
  local ns="$1" want="$2"; shift 2
  for _ in $(seq 1 18); do [[ "$(probe "$ns" "$@")" == "$want" ]] && return 0; sleep 5; done
  return 1
}

run_tests() { # PHASE (avant|apres)
  local phase="$1" c
  ensure_probes
  log "== Tests ($phase) : isole=$ISO_NS temoin=$CTRL_NS"
  # Temoins positifs : DNS et apiserver (TLS verifie avec kube-root-ca.crt, sans jeton).
  kubectl -n "$ISO_NS" exec "$POD" -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 \
    && res PASS S-dns-iso "DNS depuis $ISO_NS" || res FAIL S-dns-iso "DNS refuse depuis $ISO_NS"
  c="$(probe "$ISO_NS" --cacert /ca/ca.crt https://kubernetes.default.svc/version)"
  [[ "$c" == OPEN ]] && res PASS S-api-iso "apiserver joignable depuis $ISO_NS" || res FAIL S-api-iso "apiserver depuis $ISO_NS : $c"
  c="$(probe "$CTRL_NS" https://1.1.1.1/)"
  [[ "$c" == OPEN ]] && res PASS S-open-ctrl "namespace non isole : 1.1.1.1:443 $c (comportement inchange)" \
    || res FAIL S-open-ctrl "namespace non isole : 1.1.1.1:443 $c (attendu OPEN)"
  # IMDS : refus par port, avec temoin :53 sur le meme hote (namespace non isole).
  c="$(probe "$CTRL_NS" http://169.254.169.254/opc/v2/instance/)"
  if [[ "$c" == TIMEOUT ]] && kubectl -n "$CTRL_NS" exec "$POD" -- nslookup example.com 169.254.169.254 >/dev/null 2>&1; then
    res PASS S-imds-ctrl "IMDS :80 TIMEOUT, 169.254.169.254:53 repond"
  else res FAIL S-imds-ctrl "IMDS :80 depuis $CTRL_NS : $c"; fi
  c="$(probe "$ISO_NS" http://169.254.169.254/opc/v2/instance/)"
  [[ "$c" == TIMEOUT ]] && res PASS S-imds-iso "IMDS :80 TIMEOUT depuis $ISO_NS" || res FAIL S-imds-iso "IMDS depuis $ISO_NS : $c"
  # Refus : egress Internet du namespace isole.
  if [[ "$phase" == apres ]]; then
    if wait_class "$ISO_NS" TIMEOUT https://1.1.1.1/; then
      res PASS S-egress-iso "1.1.1.1:443 TIMEOUT depuis $ISO_NS, temoin OPEN : default-deny effectif"
    else res FAIL S-egress-iso "1.1.1.1:443 depuis $ISO_NS : $(probe "$ISO_NS" https://1.1.1.1/) (attendu TIMEOUT)"; fi
  else
    log "INFO S-egress-iso (avant) : 1.1.1.1:443 depuis $ISO_NS = $(probe "$ISO_NS" https://1.1.1.1/) (C1 : OPEN attendu)"
  fi
  # Controllers et webhooks legitimes des namespaces isoles : deploiements disponibles,
  # leases (age de renouvellement, INFO : un lease orphelin peut etre ancien par conception),
  # redemarrages (a comparer avant/apres).
  local ns line
  for ns in $(kubectl get ns -l "$LABEL=true" -o jsonpath='{.items[*].metadata.name}'); do
    while read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "$line" =~ ready=([0-9]+)/([0-9]+) && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
        res PASS S-deploy "$line"; else res FAIL S-deploy "$line"; fi
    done < <(kubectl -n "$ns" get deploy -o json | jq -r --arg ns "$ns" \
      '.items[] | "\($ns)/\(.metadata.name) ready=\(.status.readyReplicas // 0)/\(.spec.replicas)"')
    kubectl -n "$ns" get lease -o json | jq -r --arg ns "$ns" \
      '.items[] | select(.spec.renewTime != null)
       | "INFO lease \($ns)/\(.metadata.name) age=\(now - (.spec.renewTime | sub("\\.[0-9]+"; "") | fromdateiso8601) | floor)s"'
    kubectl -n "$ns" get pods --no-headers -o custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount \
      | sed "s|^|INFO restarts $ns/|"
  done
  # Drops Cilium des 30 dernieres secondes (Hubble desactive : moniteur de l'agent, lecture seule).
  log "== Drops Cilium (30 s)"
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- timeout 30 cilium-dbg monitor --type drop 2>/dev/null | tail -40 || true
}

guard
case "${1:-}" in
  plan) plan;;
  backup) backup;;
  apply) apply_fix;;
  test) run_tests apres;;
  rollback) rollback;;
  all) plan; backup; run_tests avant; apply_fix; run_tests apres;;
  *) echo "usage : $0 plan|backup|apply|test|rollback|all" >&2; exit 2;;
esac
log "FAIL=$FAILS"
(( FAILS == 0 ))
