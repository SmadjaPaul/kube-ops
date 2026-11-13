#!/usr/bin/env bash
# Provisioning et contrôle du kubeconfig de l'identité agent-operator (PLT-237).
#
# Usage (Mac natif, Doppler authentifié, accès opérateur canonique) :
#   bash scripts/agent-operator-token.sh --check-cluster   préconditions RECONCILED, aucune écriture
#   bash scripts/agent-operator-token.sh --provision       émet le jeton, l'écrit dans Doppler, vérifie
#   bash scripts/agent-operator-token.sh --verify          relit la copie Doppler et prouve le périmètre
#
# --provision :
#   1. accès opérateur via scripts/lib/kube-preflight.sh (copie canonique) ;
#   2. vérifie que Argo a réconcilié SA, ClusterRoles, RoleBindings (scope.tsv)
#      et la policy agent-operator-guard ;
#   3. TokenRequest (kubectl create token, durée AGENT_TOKEN_DURATION, 720h par
#      défaut) vers un fichier 0600 d'un dossier temporaire supprimé à la sortie ;
#   4. kubeconfig agent : même serveur et même CA que la copie opérateur, jeton
#      écrit par python depuis le fichier (jamais en argument ni à l'écran) ;
#   5. contrôles avec ce kubeconfig (whoami + can-i, voir --verify) ;
#   6. écriture Doppler infrastructure/prd par scripts/doppler-safe.sh set :
#      KUBERNETES_AGENT_OPERATOR_KUBECONFIG puis
#      KUBERNETES_AGENT_OPERATOR_KUBECONFIG_SHA256 (empreinte calculée comme
#      kube-preflight.sh) ;
#   7. --verify sur la copie relue depuis Doppler.
# Sortie : uniquement des statuts, l'empreinte tronquée et la date d'expiration.
#
# Rotation : relancer --provision avant l'expiration. Révocation immédiate :
# supprimer le ServiceAccount (rollback PLT-237) invalide tous ses jetons.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCOPE=$ROOT/k8s/infrastructure/security/agent-operator/scope.tsv
NS=agent-operator
SA=agent-operator
AGENT_USER=system:serviceaccount:$NS:$SA
SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG
DURATION=${AGENT_TOKEN_DURATION:-720h}

die() { echo "agent-operator-token: $1" >&2; exit "${2:-1}"; }
mode=${1:-}
case "$mode" in --check-cluster|--provision|--verify) ;; *) die "usage : --check-cluster | --provision | --verify" 64 ;; esac
[[ "$DURATION" =~ ^[0-9]{1,5}h$ ]] || die "AGENT_TOKEN_DURATION invalide (ex. 720h)" 64

admitted=$(grep -vE '^#|^$' "$SCOPE" | cut -f1)

# --verify : preuves de périmètre avec le KUBECONFIG courant (identité agent).
# Ne lit aucun Secret : can-i interroge seulement l'autorisation.
verify_agent() {
  local who fails=0 ns
  who=$(kubectl --request-timeout=15s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
  if [ "$who" = "$AGENT_USER" ]; then echo "CHECK whoami=$who PASS"; else echo "CHECK whoami='$who' FAIL"; fails=1; fi
  can() { # can ATTENDU VERBE RESSOURCE [args...]
    local want=$1 got
    shift
    got=$(kubectl --request-timeout=15s auth can-i "$@" 2>/dev/null)
    if [ "$got" = "$want" ]; then echo "CHECK can-i $* = $got PASS"; else echo "CHECK can-i $* = '$got' (attendu $want) FAIL"; fails=1; fi
  }
  can no get secrets --all-namespaces
  can no list secrets -n media
  can no get secrets -n "$NS"
  can no patch deployments -n auth
  can no delete pods -n auth
  can no patch deployments -n matrix
  can no delete persistentvolumeclaims -n media
  can no delete persistentvolumes
  can no create rolebindings -n media
  can no create clusterrolebindings
  can no create serviceaccounts/token -n media
  can no create pods/exec -n media
  can no patch ciliumnetworkpolicies.cilium.io -n media
  can no patch httproutes.gateway.networking.k8s.io -n media
  can no delete validatingadmissionpolicies.admissionregistration.k8s.io
  can no patch deployments -n immich
  can no patch deployments --subresource=scale -n media
  can no impersonate users
  can yes get deployments --all-namespaces
  for ns in $admitted; do
    can yes patch deployments -n "$ns"
  done
  can yes delete pods -n media
  can yes patch cronjobs -n media
  return "$fails"
}

if [ "$mode" = --verify ]; then
  unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR
  export KUBERC=off KUBE_ACCESS_KUBECONFIG_SECRET=$SECRET
  # shellcheck source=lib/kube-preflight.sh
  source "$HERE/lib/kube-preflight.sh"
  set +e
  require_kube_access >/dev/null 2>"${TMPDIR:-/tmp}/agent-operator-verify.$$" || {
    grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "${TMPDIR:-/tmp}/agent-operator-verify.$$" >&2
    rm -f "${TMPDIR:-/tmp}/agent-operator-verify.$$"
    die "copie Doppler $SECRET inutilisable" 2
  }
  rm -f "${TMPDIR:-/tmp}/agent-operator-verify.$$"
  echo "KUBE_ACCESS=PASS source=${KUBE_ACCESS_SOURCE:-?}"
  if verify_agent; then echo "AGENT_OPERATOR_VERIFY=PASS"; exit 0; fi
  echo "AGENT_OPERATOR_VERIFY=FAIL"; exit 1
fi

# --- accès opérateur canonique
unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR KUBE_ACCESS_KUBECONFIG_SECRET
export KUBERC=off
# shellcheck source=lib/kube-preflight.sh
source "$HERE/lib/kube-preflight.sh"
set +e
umask 077
require_kube_access >/dev/null || die "accès opérateur indisponible (just kube-access-check)" 2
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-operator-token.XXXXXX")
trap 'rm -rf -- "$work"; kube_access_cleanup' EXIT

# --- préconditions : objets réconciliés par Argo
pre=0
check_obj() {
  if kubectl --request-timeout=15s get "$@" -o name >/dev/null 2>&1; then echo "PRE $* PASS"; else echo "PRE $* FAIL"; pre=1; fi
}
check_obj serviceaccount/$SA -n $NS
check_obj clusterrole/agent-operator-cluster-read
check_obj clusterrole/agent-operator-workload
check_obj clusterrolebinding/agent-operator-view
check_obj clusterrolebinding/agent-operator-cluster-read
check_obj validatingadmissionpolicy/agent-operator-guard
check_obj validatingadmissionpolicybinding/agent-operator-guard
for ns in $admitted; do check_obj rolebinding/agent-operator-workload -n "$ns"; done
for app in infra-security apps-platform; do
  st=$(kubectl --request-timeout=15s get application "$app" -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}' 2>/dev/null)
  echo "ARGO $app $st"
done
[ "$pre" = 0 ] || die "préconditions non réunies : attendre la réconciliation Argo (aucun jeton émis)" 3
[ "$mode" = --check-cluster ] && { echo "AGENT_OPERATOR_CLUSTER=PASS"; exit 0; }

# --- jeton et kubeconfig agent (aucune valeur affichée)
kubectl --request-timeout=30s create token "$SA" -n "$NS" --duration="$DURATION" >"$work/token" 2>/dev/null ||
  die "TokenRequest refusé" 4
[ -s "$work/token" ] || die "jeton vide" 4
kubectl config view --raw --minify -o json >"$work/op.json" 2>/dev/null || die "lecture de la copie opérateur impossible" 4
python3 -I - "$work/op.json" "$work/token" "$work/kubeconfig" <<'PY' || die "construction du kubeconfig impossible" 4
import json, sys
op = json.load(open(sys.argv[1]))
token = open(sys.argv[2]).read().strip()
cluster = op["clusters"][0]["cluster"]
if "certificate-authority-data" not in cluster or cluster.get("insecure-skip-tls-verify"):
    sys.exit("CA absente ou TLS non vérifié dans la copie opérateur")
cfg = {
    "apiVersion": "v1", "kind": "Config",
    "clusters": [{"name": "homelab", "cluster": {"server": cluster["server"],
                  "certificate-authority-data": cluster["certificate-authority-data"]}}],
    "users": [{"name": "agent-operator", "user": {"token": token}}],
    "contexts": [{"name": "agent-operator", "context": {"cluster": "homelab", "user": "agent-operator"}}],
    "current-context": "agent-operator",
}
with open(sys.argv[3], "w") as f:
    json.dump(cfg, f)
PY
chmod 600 "$work/kubeconfig"
expires=$(python3 -I - "$work/token" <<'PY'
import base64, json, sys, datetime
p = open(sys.argv[1]).read().strip().split(".")[1]
exp = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["exp"]
print(datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
rm -f "$work/token" "$work/op.json"

KUBECONFIG="$work/kubeconfig" verify_agent || die "le nouveau jeton ne respecte pas le périmètre : rien n'est écrit dans Doppler" 5
digest=$(_kube_access_digest "$work/kubeconfig") || die "empreinte impossible" 5

bash "$HERE/doppler-safe.sh" set "$SECRET" <"$work/kubeconfig" || die "écriture Doppler $SECRET impossible" 6
printf %s "$digest" | bash "$HERE/doppler-safe.sh" set "${SECRET}_SHA256" || die "écriture Doppler ${SECRET}_SHA256 impossible" 6
rm -f "$work/kubeconfig"
echo "AGENT_TOKEN=PROVISIONED expires=$expires sha256=${digest:0:12}…"

# --- relecture depuis Doppler par le circuit canonique
KUBECONFIG="" bash "$0" --verify
