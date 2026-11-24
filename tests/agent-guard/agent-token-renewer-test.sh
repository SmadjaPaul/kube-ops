#!/usr/bin/env bash
# PLT-481 : contrat statique du renouvellement automatique du jeton agent-operator d'OKE.
# Usage : bash tests/agent-guard/agent-token-renewer-test.sh   (kubectl/kustomize, jq, yq ; aucun cluster)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
D=k8s/clusters/oracle-a1/agent-token-renewer
fails=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*" >&2; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }

# 1. une seule liste de controles : celle de verify_agent
mine=$(grep -E '^can (no|yes) ' "$D/renew.sh")
ref=$(sed -n '/^verify_agent()/,/^}/p' scripts/agent-operator-oke-token.sh | grep -E '^  can (no|yes) ' | sed 's/^  //')
[ "$(echo "$mine" | wc -l | tr -d ' ')" = 16 ] && ok "16 controles can-i" || ko "nombre de controles can-i != 16"
[ "$mine" = "$ref" ] && ok "controles = verify_agent" || ko "controles de renew.sh != verify_agent"

# 2. l'ecriture Doppler suit les controles, et le jeton n'est jamais affiche
awk '/die "AGENT_TOKEN_RENEW=FAIL/{c=NR} /--data @-/{w=NR} END{exit !(c && w && c < w)}' "$D/renew.sh" &&
  ok "ecriture apres controles" || ko "ecriture avant les controles"
! grep -nE 'echo[^|]*(\$token|\$tok|kubeconfig)|cat "\$W/(token|kubeconfig)"' "$D/renew.sh" >/dev/null && ok "jeton jamais affiche" || ko "jeton affiche"
check "bash -n renew.sh" bash -n "$D/renew.sh"

# 3. le calcul de l'empreinte est celui du client
grep -q "kubectl config view --raw --minify -o json | sha256sum" "$D/renew.sh" &&
  grep -q 'config view --raw --minify -o json' scripts/lib/kube-preflight.sh && ok "empreinte = _kube_access_digest" || ko "empreinte differente"

# 4. rendu : droits minimaux, cronjob 6 h epingle par digest, egress ferme
R=$(kubectl kustomize "$D" 2>/dev/null || kustomize build "$D")
rules=$(echo "$R" | yq -N 'select(.kind == "Role") | .rules' -o=json | jq -cS '.')
[ "$rules" = '[{"apiGroups":[""],"resourceNames":["agent-operator"],"resources":["serviceaccounts/token"],"verbs":["create"]}]' ] &&
  ok "Role = create serviceaccounts/token agent-operator seul" || ko "Role trop large : $rules"
[ "$(echo "$R" | yq -N 'select(.kind == "CronJob") | .spec.schedule')" = "0 */6 * * *" ] && ok "CronJob 6 h" || ko "schedule"
[ "$(echo "$R" | yq -N 'select(.kind == "CronJob") | .spec.concurrencyPolicy')" = Forbid ] && ok "concurrencyPolicy Forbid" || ko "concurrencyPolicy"
echo "$R" | yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].image' | grep -Eq '@sha256:[0-9a-f]{64}$' && ok "image epinglee par digest" || ko "image sans digest"
[ "$(echo "$R" | yq -N 'select(.kind == "Namespace") | .metadata.labels["platform.smadja.dev/egress-isolated"]')" = true ] && ok "namespace isole" || ko "namespace non isole"
fq=$(echo "$R" | yq -N 'select(.kind == "CiliumNetworkPolicy") | .spec.egress[].toFQDNs[].matchName')
[ "$fq" = api.doppler.com ] && ok "egress FQDN = api.doppler.com seul" || ko "egress FQDN : $fq"
grep -qE '^kind: ClusterRole|resources:.*secrets' "$D/rbac.yaml" && ko "rbac.yaml ne doit ni toucher de Secret ni de ClusterRole" || ok "aucun Secret ni ClusterRole dans rbac.yaml"
# 5. branche dans l'ApplicationSet et le projet
grep -q 'k8s/clusters/oracle-a1/agent-token-renewer' k8s/clusters/oracle-a1/argocd-root/infrastructure-applicationset.yaml && ok "dans l'ApplicationSet" || ko "absent de l'ApplicationSet"
grep -q 'namespace: agent-token-renewer' k8s/clusters/oracle-a1/argocd-root/infrastructure-project.yaml && ok "destination du projet" || ko "destination absente"
[ "$fails" = 0 ] && echo AGENT_TOKEN_RENEWER_TEST=PASS || { echo "AGENT_TOKEN_RENEWER_TEST=FAIL ($fails)"; exit 1; }
