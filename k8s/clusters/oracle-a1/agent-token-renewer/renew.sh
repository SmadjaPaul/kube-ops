#!/usr/bin/env bash
# Renouvelle le kubeconfig agent-operator d'OKE (PLT-481). Sortie : statuts seulement, jamais le jeton.
# 1. TokenRequest 24 h pour argocd/agent-operator (droit unique du ServiceAccount du Job).
# 2. kubeconfig : serveur OKE_API_SERVER (Doppler agent-access/prd, adresse privee du VCN), CA du pod.
# 3. 16 controles `can-i` + whoami avec ce jeton contre ce serveur ; un echec n'ecrit RIEN.
# 4. Empreinte (meme commande que _kube_access_digest de scripts/lib/kube-preflight.sh), puis ecriture
#    des deux cles dans agent-access/prd en une seule requete.
# La liste des controles est celle de verify_agent (scripts/agent-operator-oke-token.sh) :
# tests/agent-guard/agent-token-renewer-test.sh interdit toute derive.
set -euo pipefail
umask 077

NS=argocd
SA=agent-operator
SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1
PROJECT=agent-access
CONFIG=prd
API=https://api.doppler.com/v3/configs/config
W=/tmp/w
mkdir -p "$W"

die() { echo "agent-token-renewer: $1" >&2; exit "${2:-1}"; }

printf 'Authorization: Bearer %s\n' "$(cat /etc/doppler/token)" >"$W/hdr"
doppler_get() { curl -fsS --max-time 20 -H "@$W/hdr" -G "$API/secret" --data-urlencode "project=$PROJECT" --data-urlencode "config=$CONFIG" --data-urlencode "name=$1"; }

server=$(doppler_get OKE_API_SERVER | jq -r '.value.computed // empty') || die "lecture d'OKE_API_SERVER impossible (geste de Paul : --provision amorce la config)" 3
[ -n "$server" ] || die "OKE_API_SERVER absent de $PROJECT/$CONFIG" 3
# Meme regle que oke_api_server_valid : https://10.0.x.y[:port], octets <= 255, jamais d'adresse inattendue.
echo "$server" | grep -Eq '^https://10\.0\.[0-9]{1,3}\.[0-9]{1,3}(:[0-9]{1,5})?/?$' || die "OKE_API_SERVER hors VCN OKE : rien n'est ecrit" 4
echo "$server" | grep -Eo '10\.0\.[0-9]+\.[0-9]+' | tr . '\n' | awk '$1>255{bad=1} END{exit bad}' || die "OKE_API_SERVER invalide : rien n'est ecrit" 4

kubectl create token "$SA" -n "$NS" --duration=24h >"$W/token" 2>/dev/null || die "TokenRequest refuse" 4
[ -s "$W/token" ] || die "jeton vide" 4
jq -n --arg server "$server" --rawfile token "$W/token" \
  --arg ca "$(base64 </var/run/secrets/kubernetes.io/serviceaccount/ca.crt | tr -d '\n')" '{
  apiVersion: "v1", kind: "Config",
  clusters: [{name: "oracle-a1", cluster: {server: $server, "certificate-authority-data": $ca}}],
  users: [{name: "agent-operator", user: {token: ($token | rtrimstr("\n"))}}],
  contexts: [{name: "agent-operator", context: {cluster: "oracle-a1", user: "agent-operator"}}],
  "current-context": "agent-operator"}' >"$W/kubeconfig"
rm -f "$W/token"
export KUBECONFIG="$W/kubeconfig"

fails=0
who=$(kubectl --request-timeout=15s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)
if [ "$who" = "system:serviceaccount:$NS:$SA" ]; then echo "CHECK whoami=$who PASS"; else echo "CHECK whoami='$who' FAIL"; fails=1; fi
can() { # can ATTENDU args...
  local want=$1 got
  shift
  got=$(kubectl --request-timeout=15s auth can-i "$@" 2>/dev/null | awk 'NR==1{print $1}' || true)
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
[ "$fails" = 0 ] || die "AGENT_TOKEN_RENEW=FAIL : controles refuses, rien n'est ecrit dans Doppler" 5

digest=$(kubectl config view --raw --minify -o json | sha256sum | cut -d' ' -f1)
[ -n "$digest" ] || die "empreinte impossible" 5
jq -n --rawfile kc "$W/kubeconfig" --arg sha "$digest" --arg p "$PROJECT" --arg c "$CONFIG" --arg k "$SECRET" \
  '{project: $p, config: $c, secrets: {($k): $kc, ($k + "_SHA256"): $sha}}' |
  curl -fsS --max-time 20 -X POST -H "@$W/hdr" -H 'Content-Type: application/json' --data @- "$API/secrets" >/dev/null ||
  die "ecriture Doppler $PROJECT/$CONFIG impossible" 6
echo "AGENT_TOKEN_RENEW=PASS written=$PROJECT/$CONFIG sha256=${digest:0:12}..."
