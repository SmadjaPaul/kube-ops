#!/usr/bin/env bash
# Écriture Kubernetes bornée, avec l'identité agent-operator (PLT-237,
# D-2026-11-13-01). Seule entrée d'écriture impérative des agents ;
# scripts/kubectl-ro.sh reste la seule entrée de lecture.
#
# Usage : bash scripts/kubectl-rw.sh [--dry-run] <verbe> <namespace> <cible> [arg]
#   patch     NS KIND/NAME PATCH_JSON [strategic|merge|json]   deployment|statefulset|daemonset|job|cronjob
#   scale     NS KIND/NAME REPLICAS     deployment|statefulset (patch de spec.replicas)
#   restart   NS KIND/NAME              deployment|statefulset|daemonset (rollout restart)
#   undo      NS KIND/NAME              deployment|statefulset|daemonset (rollout undo)
#   set-image NS KIND/NAME CONTAINER=IMAGE   deployment|statefulset|daemonset|cronjob
#   suspend   NS KIND/NAME              job|cronjob (spec.suspend=true)
#   resume    NS KIND/NAME              job|cronjob (spec.suspend=false)
#   delete    NS KIND/NAME              pod|job|replicaset|deployment|statefulset|daemonset|cronjob
#   apply     NS FILE                   server-side, field manager agent-operator ;
#                                       Deployment|StatefulSet|DaemonSet|Job|CronJob seulement
#
# Contrôles avant tout appel : namespace dans
# k8s/infrastructure/security/agent-operator/scope.tsv, verbe et type admis,
# nom DNS-1123, aucune option libre (kubeconfig, token, impersonation, TLS,
# --force, --grace-period, sélecteurs, --all sont impossibles par construction).
# L'API applique ensuite le RBAC agent-operator-workload et la policy
# agent-operator-guard (Secret, PVC, RBAC, réseau, smadja.dev/agent-protected).
#
# Accès : scripts/lib/kube-preflight.sh avec
# KUBE_ACCESS_KUBECONFIG_SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG (Doppler
# infrastructure/prd, empreinte SHA-256, TLS vérifié). Refus si l'identité
# effective n'est pas system:serviceaccount:agent-operator:agent-operator :
# jamais d'écriture avec la copie opérateur.
#
# Après succès : vérification runtime (rollout status, état suspend, absence
# après delete), journal TSV (KUBECTL_RW_LOG, défaut
# ${XDG_STATE_HOME:-~/.local/state}/kube-ops/kubectl-rw.log) et rappel GitOps :
# Argo selfHeal annule tout champ géré par Git ; un changement durable passe par
# une PR le jour même.
#
# KUBECTL_RW_PLAN=1 : contrôles seulement, affiche la commande kubectl prévue,
# aucun accès au cluster (tests, prévisualisation).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCOPE=${KUBECTL_RW_SCOPE:-$ROOT/k8s/infrastructure/security/agent-operator/scope.tsv}
AGENT_USER=system:serviceaccount:agent-operator:agent-operator
ROLLOUT_TIMEOUT=${KUBECTL_RW_ROLLOUT_TIMEOUT:-180s}

refuse() { echo "kubectl-rw: refusé : $*" >&2; exit 64; }

dry=0
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
[ "$#" -ge 3 ] || refuse "usage : kubectl-rw.sh [--dry-run] <verbe> <namespace> <cible> [arg] (voir l'en-tête)"
verb=$1 ns=$2 target=$3
shift 3
[ "$#" -le 2 ] || refuse "arguments en trop"

[ -r "$SCOPE" ] || refuse "périmètre introuvable : $SCOPE"
grep -vE '^#|^$' "$SCOPE" | cut -f1 | grep -qxF -- "$ns" ||
  refuse "namespace '$ns' hors périmètre agent-operator (scope.tsv)"

DNS='^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$'
kind=""
name=""
if [ "$verb" != apply ]; then
  case "$target" in */*) ;; *) refuse "cible '$target' : forme KIND/NAME attendue" ;; esac
  raw_kind=${target%%/*}
  name=${target#*/}
  case "$raw_kind" in
    deploy|deployment|deployments) kind=deployment ;;
    sts|statefulset|statefulsets) kind=statefulset ;;
    ds|daemonset|daemonsets) kind=daemonset ;;
    rs|replicaset|replicasets) kind=replicaset ;;
    job|jobs) kind=job ;;
    cj|cronjob|cronjobs) kind=cronjob ;;
    po|pod|pods) kind=pod ;;
    *) refuse "type '$raw_kind' hors périmètre (workloads, Jobs, Pods)" ;;
  esac
  [[ "$name" =~ $DNS ]] || refuse "nom '$name' invalide (DNS-1123)"
fi

pinned_image() { # pinned_image IMAGE : tag explicite (ni latest ni main) ou digest
  local img=$1 last
  case "$img" in *@sha256:*) return 0 ;; esac
  last=${img##*/}
  case "$last" in *:*) ;; *) return 1 ;; esac
  case "${last##*:}" in ''|latest|main) return 1 ;; esac
  return 0
}

allow_kinds() { # allow_kinds K... : refuse si $kind n'est pas dans la liste
  local k
  for k in "$@"; do [ "$kind" = "$k" ] && return 0; done
  refuse "verbe '$verb' non admis pour '$kind' (admis : $*)"
}

cmd=()
case "$verb" in
  patch)
    allow_kinds deployment statefulset daemonset job cronjob
    [ "$#" -ge 1 ] || refuse "patch : PATCH_JSON manquant"
    ptype=${2:-strategic}
    case "$ptype" in strategic|merge|json) ;; *) refuse "type de patch '$ptype' (strategic|merge|json)" ;; esac
    if [ "$ptype" = json ]; then
      jq -e 'type == "array"' <<<"$1" >/dev/null 2>&1 || refuse "patch json : tableau JSON attendu"
    else
      jq -e 'type == "object"' <<<"$1" >/dev/null 2>&1 || refuse "patch : objet JSON attendu"
    fi
    cmd=(patch "$kind/$name" -n "$ns" --type="$ptype" -p "$1") ;;
  scale)
    allow_kinds deployment statefulset
    [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]{1,3}$ ]] || refuse "scale : REPLICAS entier (0-999) attendu"
    cmd=(patch "$kind/$name" -n "$ns" --type=merge -p "{\"spec\":{\"replicas\":$((10#$1))}}") ;;
  restart|undo)
    allow_kinds deployment statefulset daemonset
    [ "$#" -eq 0 ] || refuse "$verb ne prend pas d'argument"
    cmd=(rollout "$verb" "$kind/$name" -n "$ns") ;;
  set-image)
    allow_kinds deployment statefulset daemonset cronjob
    [ "$#" -eq 1 ] && [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?=[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] ||
      refuse "set-image : CONTAINER=IMAGE attendu"
    pinned_image "${1#*=}" || refuse "image non épinglée (tag explicite ou digest requis ; latest/main interdits)"
    cmd=(set image "$kind/$name" -n "$ns" "$1") ;;
  suspend|resume)
    allow_kinds job cronjob
    [ "$#" -eq 0 ] || refuse "$verb ne prend pas d'argument"
    want=true
    [ "$verb" = resume ] && want=false
    cmd=(patch "$kind/$name" -n "$ns" --type=merge -p "{\"spec\":{\"suspend\":$want}}") ;;
  delete)
    allow_kinds pod job replicaset deployment statefulset daemonset cronjob
    [ "$#" -eq 0 ] || refuse "delete ne prend pas d'argument (ni --force ni --grace-period)"
    cmd=(delete "$kind/$name" -n "$ns" --wait=false) ;;
  apply)
    [ "$#" -eq 0 ] || refuse "apply NS FILE seulement"
    file=$target
    [ -f "$file" ] && [ ! -L "$file" ] || refuse "apply : fichier régulier attendu (ni '-', ni URL, ni dossier, ni lien)"
    command -v yq >/dev/null 2>&1 || refuse "apply : yq requis pour contrôler le fichier"
    docs=$(yq -N '(.kind // "") + "|" + (.metadata.namespace // "") + "|" + (.metadata.name // "")' "$file" 2>/dev/null) ||
      refuse "apply : YAML illisible"
    [ -n "$docs" ] || refuse "apply : fichier vide"
    while IFS='|' read -r dk dns dn; do
      case "$dk" in Deployment|StatefulSet|DaemonSet|Job|CronJob) ;; *) refuse "apply : kind '$dk' hors périmètre" ;; esac
      [ -z "$dns" ] || [ "$dns" = "$ns" ] || refuse "apply : namespace '$dns' différent de '$ns'"
      [[ "$dn" =~ $DNS ]] || refuse "apply : nom '$dn' invalide"
    done <<<"$docs"
    images=$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' "$file" 2>/dev/null) ||
      refuse "apply : lecture des images impossible"
    while read -r img; do
      [ -z "$img" ] || pinned_image "$img" || refuse "apply : image '$img' non épinglée"
    done <<<"$images"
    cmd=(apply --server-side --field-manager=agent-operator -n "$ns" -f "$file") ;;
  *) refuse "verbe '$verb' hors liste (patch|scale|restart|undo|set-image|suspend|resume|delete|apply)" ;;
esac
[ "$dry" = 0 ] || cmd+=(--dry-run=server)

if [ "${KUBECTL_RW_PLAN:-0}" = 1 ]; then
  printf 'KUBECTL_RW_PLAN=kubectl'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  exit 0
fi

# --- accès : copie Doppler de l'identité agent-operator, jamais l'ambiante
export KUBERC=off
unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR
export KUBE_ACCESS_KUBECONFIG_SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG
# shellcheck source=lib/kube-preflight.sh
source "$HERE/lib/kube-preflight.sh"
set +e
umask 077
status_file=$(mktemp "${TMPDIR:-/tmp}/kubectl-rw.XXXXXX")
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT
if ! require_kube_access >"$status_file" 2>&1; then
  grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "$status_file" >&2
  exit 2
fi
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT

who=$(kubectl --request-timeout=15s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
[ "$who" = "$AGENT_USER" ] || { echo "kubectl-rw: refusé : identité effective '$who' ≠ $AGENT_USER" >&2; exit 2; }

log=${KUBECTL_RW_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/kube-ops/kubectl-rw.log}
mkdir -p "$(dirname "$log")"
journal() { # journal STATUT
  local head arg_digest
  head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo -)
  arg_digest=$(printf '%s\0' "${cmd[@]}" | _kube_access_sha256_stream | cut -c1-12)
  printf '%s\t%s\t%s\t%s\t%s\t%s\tdry=%s\targs-sha=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$who" "$head" "$verb" "$ns" "$target" "$dry" "$arg_digest" "$1" >>"$log"
}

kubectl --request-timeout=30s "${cmd[@]}"
rc=$?
if [ "$rc" != 0 ]; then
  journal "FAIL rc=$rc"
  echo "KUBECTL_RW=FAIL rc=$rc" >&2
  exit "$rc"
fi
if [ "$dry" = 1 ]; then
  journal "DRY-RUN"
  echo "KUBECTL_RW=DRY_RUN_PASS"
  exit 0
fi

# --- vérification runtime associée
verify=PASS
rollout_targets=()
case "$verb" in
  patch|scale|restart|undo|set-image)
    case "$kind" in deployment|statefulset|daemonset) rollout_targets+=("$kind/$name") ;; esac ;;
  apply)
    while IFS='|' read -r dk _ dn; do
      case "$dk" in Deployment|StatefulSet|DaemonSet) rollout_targets+=("$(tr '[:upper:]' '[:lower:]' <<<"$dk")/$dn") ;; esac
    done <<<"$docs" ;;
  suspend|resume)
    got=$(kubectl --request-timeout=15s get "$kind/$name" -n "$ns" -o jsonpath='{.spec.suspend}' 2>/dev/null)
    [ "$got" = "$want" ] || verify=FAIL
    echo "VERIFY $kind/$name spec.suspend=$got (attendu $want)" ;;
  delete)
    if dts=$(kubectl --request-timeout=15s get "$kind/$name" -n "$ns" -o jsonpath='{.metadata.deletionTimestamp}' 2>"$status_file"); then
      if [ -n "$dts" ]; then
        echo "VERIFY $kind/$name en cours de suppression depuis $dts (finalizers ou arrêt gracieux)"
      else
        echo "VERIFY $kind/$name toujours présent sans suppression en cours"
        verify=FAIL
      fi
    elif grep -q 'NotFound' "$status_file"; then
      echo "VERIFY $kind/$name absent"
    else
      echo "VERIFY $kind/$name : contrôle impossible ($(head -1 "$status_file"))"
      verify=FAIL
    fi ;;
esac
for rt in "${rollout_targets[@]}"; do
  kubectl --request-timeout=0 rollout status "$rt" -n "$ns" --timeout="$ROLLOUT_TIMEOUT" || verify=FAIL
done

if [ "$verify" = PASS ]; then
  journal "OK verify=PASS"
  echo "KUBECTL_RW=PASS VERIFY=PASS"
else
  journal "VERIFY_FAIL (commande appliquée, résultat runtime non établi)"
  echo "KUBECTL_RW=FAIL VERIFY=FAIL (commande appliquée, résultat runtime non établi)" >&2
fi
echo "RAPPEL : Argo selfHeal annule tout champ géré par Git. Changement durable => PR GitOps le jour même (branche -> checks -> PR -> merge -> Argo -> preuve runtime)."
[ "$verify" = PASS ] || exit 3
