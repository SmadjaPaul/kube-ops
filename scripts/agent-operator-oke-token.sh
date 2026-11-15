#!/usr/bin/env bash
# Identité de lecture seule des agents sur OKE (PLT-257) : émission et contrôle.
#
# Usage :
#   --provision  PAR PAUL (session administrateur OKE, ex. kubeconfig OCI en
#                PRIVATE_ENDPOINT par NetBird) : TokenRequest 720 h pour
#                argocd/agent-operator, kubeconfig agent (serveur
#                https://10.0.2.3:6443, CA de la session admin), écriture Doppler
#                infrastructure/prd KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1
#                puis ..._SHA256, enfin --verify. Aucun jeton affiché ni passé en argument.
#   --verify     par les agents : relit la copie Doppler par kubectl-ro.sh/preflight
#                et prouve le périmètre (identité, droits refusés, droits de lecture).
# Le kubeconfig exec OCI (clé API de Paul) n'est jamais distribué : seul le jeton
# du ServiceAccount l'est. Révocation immédiate : supprimer le ServiceAccount
# (retirer agent-operator.yaml de la racine oracle-a1).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS=argocd
SA=agent-operator
AGENT_USER=system:serviceaccount:$NS:$SA
SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1
SERVER=https://10.0.2.3:6443
DURATION=${AGENT_TOKEN_DURATION:-720h}

die() { echo "agent-operator-oke-token: $1" >&2; exit "${2:-1}"; }
mode=${1:-}
case "$mode" in --provision|--verify) ;; *) die "usage : --provision | --verify" 64 ;; esac
[[ "$DURATION" =~ ^[0-9]{1,5}h$ ]] || die "AGENT_TOKEN_DURATION invalide (ex. 720h)" 64
export KUBERC=off

verify_agent() { # KUBECONFIG courant = identité agent
  local who fails=0
  who=$(kubectl --request-timeout=15s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
  if [ "$who" = "$AGENT_USER" ]; then echo "CHECK whoami=$who PASS"; else echo "CHECK whoami='$who' FAIL"; fails=1; fi
  can() { # can ATTENDU args...
    local want=$1 got
    shift
    got=$(kubectl --request-timeout=15s auth can-i "$@" 2>/dev/null)
    if [ "$got" = "$want" ]; then echo "CHECK can-i $* = $got PASS"; else echo "CHECK can-i $* = '$got' (attendu $want) FAIL"; fails=1; fi
  }
  can no get secrets --all-namespaces
  can no list secrets -n external-secrets
  can no get secrets -n "$NS"
  can no create pods/exec -n hindsight
  can no create pods/portforward -n hindsight
  can no patch deployments -n "$NS"
  can no delete pods -n "$NS"
  can no create pods -n "$NS"
  can no delete namespaces
  can no create clusterrolebindings
  can no create serviceaccounts/token -n "$NS"
  can no impersonate users
  can yes get nodes
  can yes list namespaces
  can yes list pods --all-namespaces
  can yes get applications.argoproj.io -n "$NS"
  return "$fails"
}

if [ "$mode" = --verify ]; then
  unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR
  export KUBE_ACCESS_KUBECONFIG_SECRET=$SECRET
  # shellcheck source=lib/kube-preflight.sh
  source "$HERE/lib/kube-preflight.sh"
  set +e
  err=$(mktemp "${TMPDIR:-/tmp}/oke-verify.XXXXXX")
  require_kube_access >/dev/null 2>"$err" || {
    grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "$err" >&2
    rm -f "$err"
    die "copie Doppler $SECRET inutilisable" 2
  }
  rm -f "$err"
  trap 'kube_access_cleanup' EXIT
  echo "KUBE_ACCESS=PASS source=${KUBE_ACCESS_SOURCE:-?}"
  if verify_agent; then echo "AGENT_OPERATOR_OKE_VERIFY=PASS"; exit 0; fi
  echo "AGENT_OPERATOR_OKE_VERIFY=FAIL"; exit 1
fi

# --- --provision : la session administrateur est celle du KUBECONFIG courant
command -v kubectl >/dev/null || die "kubectl manquant" 2
command -v doppler >/dev/null || die "doppler manquant" 2
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-operator-oke.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
kubectl --request-timeout=30s get serviceaccount "$SA" -n "$NS" -o name >/dev/null 2>&1 ||
  die "ServiceAccount $NS/$SA absent : attendre la synchro Argo de l'application agent-operator" 3
kubectl --request-timeout=30s get clusterrolebinding agent-operator-view agent-operator-cluster-read -o name >/dev/null 2>&1 ||
  die "ClusterRoleBindings agent-operator absents : attendre la synchro Argo" 3
kubectl --request-timeout=30s create token "$SA" -n "$NS" --duration="$DURATION" >"$work/token" 2>/dev/null || die "TokenRequest refusé" 4
[ -s "$work/token" ] || die "jeton vide" 4
kubectl config view --raw --minify -o json >"$work/admin.json" 2>/dev/null || die "lecture de la session administrateur impossible" 4
python3 -I - "$work/admin.json" "$work/token" "$work/kubeconfig" "$SERVER" <<'PY' || die "construction du kubeconfig impossible" 4
import json, sys
adm = json.load(open(sys.argv[1]))
token = open(sys.argv[2]).read().strip()
cluster = adm["clusters"][0]["cluster"]
if "certificate-authority-data" not in cluster or cluster.get("insecure-skip-tls-verify"):
    sys.exit("CA absente ou TLS non vérifié dans la session administrateur")
cfg = {
    "apiVersion": "v1", "kind": "Config",
    "clusters": [{"name": "oracle-a1", "cluster": {"server": sys.argv[4],
                  "certificate-authority-data": cluster["certificate-authority-data"]}}],
    "users": [{"name": "agent-operator", "user": {"token": token}}],
    "contexts": [{"name": "agent-operator", "context": {"cluster": "oracle-a1", "user": "agent-operator"}}],
    "current-context": "agent-operator",
}
json.dump(cfg, open(sys.argv[3], "w"))
PY
expires=$(python3 -I - "$work/token" <<'PY'
import base64, json, sys, datetime
p = open(sys.argv[1]).read().strip().split(".")[1]
exp = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["exp"]
print(datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
rm -f "$work/token" "$work/admin.json"
KUBECONFIG="$work/kubeconfig" verify_agent || die "le jeton ne respecte pas le périmètre : rien n'est écrit dans Doppler" 5
# même empreinte que kube-preflight.sh
# shellcheck source=lib/kube-preflight.sh
source "$HERE/lib/kube-preflight.sh"
set +e
digest=$(_kube_access_digest "$work/kubeconfig") || die "empreinte impossible" 5
bash "$HERE/doppler-safe.sh" set "$SECRET" <"$work/kubeconfig" || die "écriture Doppler $SECRET impossible" 6
printf %s "$digest" | bash "$HERE/doppler-safe.sh" set "${SECRET}_SHA256" || die "écriture ${SECRET}_SHA256 impossible : relancer --provision" 6
rm -f "$work/kubeconfig"
echo "AGENT_TOKEN=PROVISIONED expires=$expires sha256=${digest:0:12}…"
exec bash "$0" --verify
