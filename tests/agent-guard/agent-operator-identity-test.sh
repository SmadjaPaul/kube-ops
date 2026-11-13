#!/usr/bin/env bash
# PLT-237 — contrat statique de l'identité agent-operator.
# Usage : bash tests/agent-guard/agent-operator-identity-test.sh
# Requiert yq (v4) et jq. Aucun accès cluster, aucun Doppler réel.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
DIR=k8s/infrastructure/security/agent-operator
SCOPE=$DIR/scope.tsv
RB=k8s/applications/platform/agent-operator-access/rolebindings.yaml
VAP=$DIR/validatingadmissionpolicy.yaml
RBAC=$DIR/rbac.yaml
fails=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*" >&2; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }

scope=$(grep -vE '^#|^$' "$SCOPE" | cut -f1 | sort)
[ -n "$scope" ] || ko "scope.tsv vide"

# 1. une seule liste : scope.tsv = RoleBindings = variable admitted de la policy
rbs=$(yq -N 'select(.kind == "RoleBinding") | .metadata.namespace' "$RB" | sort)
[ "$rbs" = "$scope" ] && ok "RoleBindings = scope.tsv" || ko "RoleBindings ≠ scope.tsv"
admitted=$(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .spec.variables[] | select(.name == "admitted") | .expression' "$VAP" |
  grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort)
[ "$admitted" = "$scope" ] && ok "policy admitted = scope.tsv" || ko "policy admitted ≠ scope.tsv"
bad=$(yq -N 'select(.kind == "RoleBinding") | select(.roleRef.name != "agent-operator-workload" or .roleRef.kind != "ClusterRole" or (.subjects | length) != 1 or .subjects[0].name != "agent-operator" or .subjects[0].namespace != "agent-operator") | .metadata.namespace' "$RB")
[ -z "$bad" ] && ok "RoleBindings : rôle et sujet exacts" || ko "RoleBindings inattendus : $bad"

# 2. exclusions : identité, données irremplaçables, socle et réseau
for ns in auth matrix authentik-drill hindsight-personal home-assistant immich invoice-ninja karakeep mealie \
  paperless romm rustical-pilot sure trilium vikunja wellness librechat kube-system cilium-secrets gateway \
  cloudflared external-dns-private argocd cert-manager external-secrets longhorn-system csi-proxmox velero \
  cnpg-system kyverno gatekeeper-system falco trivy-system monitoring keda reloader arc-systems arc-runners \
  agent-sandbox-system agent-observers agent-operator default; do
  if grep -qxF "$ns" <<<"$scope"; then ko "namespace exclu admis : $ns"; fi
done
ok "aucun namespace exclu dans scope.tsv"

# 3. chaque namespace admis est une destination du projet Argo « applications »
dest=$(yq -N '.spec.destinations[].namespace' k8s/bootstrap/argocd-root/applications-project.yaml)
for ns in $scope; do grep -qxF "$ns" <<<"$dest" || ko "$ns absent des destinations du projet applications"; done
ok "namespaces admis = destinations Argo existantes"
check "destination agent-operator dans le projet infrastructure" \
  grep -qx '    - namespace: agent-operator' k8s/bootstrap/argocd-root/infrastructure-project.yaml
check "racine infra-security importe agent-operator" grep -qx '  - agent-operator' k8s/infrastructure/security/kustomization.yaml
check "racine apps-platform importe agent-operator-access" grep -qx '  - agent-operator-access' k8s/applications/platform/kustomization.yaml

# 4. RBAC : jamais de Secret, d'escalade, d'exec, de PVC/PV en écriture
rules=$(yq -o=json -I=0 'select(.kind == "ClusterRole") | {"n": .metadata.name, "r": .rules}' "$RBAC" | jq -c '.n as $n | .r[] | . + {role: $n}')
violations=$(jq -c 'select(
  ((.apiGroups | index("")) != null and ((.resources | index("*")) != null or (.resources | index("secrets")) != null)) or
  ((.resources // []) | map(test("^(secrets|persistentvolumeclaims|serviceaccounts/token|pods/(exec|attach|portforward)|.*/scale|roles|rolebindings|clusterroles|clusterrolebindings)$")) | any) and (.verbs | map(. != "get" and . != "list" and . != "watch") | any) or
  ((.resources // []) | index("secrets")) != null or
  (.verbs | map(. == "*" or . == "escalate" or . == "bind" or . == "impersonate") | any) or
  ((.resources // []) | map(test("/scale$")) | any) or
  ((.apiGroups | index("*")) != null)
)' <<<"$rules")
[ -z "$violations" ] && ok "ClusterRoles : ni Secret, ni escalade, ni exec, ni scale" || ko "règles interdites : $violations"
reads=$(jq -c 'select(.role == "agent-operator-cluster-read") | select(.verbs | map(. != "get" and . != "list" and . != "watch") | any)' <<<"$rules")
[ -z "$reads" ] && ok "cluster-read en lecture seule" || ko "cluster-read écrit : $reads"
crb=$(yq -N 'select(.kind == "ClusterRoleBinding") | .roleRef.name' "$RBAC" | sort | tr '\n' ' ')
[ "$crb" = "agent-operator-cluster-read view " ] && ok "ClusterRoleBindings = view + cluster-read" || ko "ClusterRoleBindings inattendus : $crb"
check "ServiceAccount sans montage de jeton" \
  test "$(yq -N 'select(.kind == "ServiceAccount") | .automountServiceAccountToken' "$DIR/identity.yaml")" = false
check "namespace agent-operator protégé" \
  test "$(yq -N 'select(.kind == "Namespace") | .metadata.labels["smadja.dev/agent-protected"]' "$DIR/identity.yaml")" = true
if grep -rqE 'kind: ClusterRoleBinding' k8s/applications/platform/agent-operator-access; then ko "ClusterRoleBinding dans agent-operator-access"; fi

# 5. policy : fail-closed, Deny, limitée à l'identité exacte
check "policy failurePolicy Fail" test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .spec.failurePolicy' "$VAP")" = Fail
check "binding Deny" test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions | join(",")' "$VAP")" = Deny
check "matchCondition = identité agent exacte" grep -q "request.userInfo.username == 'system:serviceaccount:agent-operator:agent-operator'" "$VAP"
check "policy : pas de sous-ressource scale admise" bash -c "! grep -q \"/scale'\" '$VAP'"
for msg in agent-protected 'cnpg.io/cluster' persistentVolumeClaimRetentionPolicy secretKeyRef secretRef serviceAccountName hostNetwork \
  persistentVolumeClaim oldCarriesCredentials 'variables.newSpec == variables.oldSpec' oldPrivileged; do
  grep -q "$msg" "$VAP" || ko "policy sans contrôle $msg"
done
ok "policy : contrôles protégé/CNPG/rétention PVC/Secret/SA/hôte présents"

# 6. wrapper kubectl-rw.sh (mode plan : contrôles sans cluster)
W=scripts/kubectl-rw.sh
ns1=$(head -1 <<<"$scope")
plan() { KUBECTL_RW_PLAN=1 bash "$W" "$@" 2>/dev/null; }
refused() { # refused DESC ARGS... : doit sortir 64 sans plan
  local d=$1 rc=0
  shift
  KUBECTL_RW_PLAN=1 bash "$W" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 64 ] && ok "rw refuse : $d" || ko "rw accepte : $d (rc=$rc)"
}
expect_plan() { # expect_plan DESC MOTIF ARGS...
  local d=$1 pat=$2 out
  shift 2
  out=$(plan "$@") && grep -qE -- "$pat" <<<"$out" && ok "rw plan : $d" || ko "rw plan : $d => ${out:-refus}"
}
expect_plan "scale = patch spec.replicas" "patch deployment/web -n $ns1 --type=merge -p .*replicas.*:2" scale "$ns1" deploy/web 2
expect_plan "restart" "rollout restart deployment/web -n $ns1\$" restart "$ns1" deployment/web
expect_plan "suspend cronjob" 'suspend.*:true' suspend "$ns1" cj/backup
expect_plan "delete pod sans --force" "delete pod/x-1 -n $ns1 --wait=false\$" delete "$ns1" pod/x-1
expect_plan "dry-run serveur" '--dry-run=server$' --dry-run restart "$ns1" deploy/web
expect_plan "set-image épinglée" 'set image' set-image "$ns1" deploy/web app=ghcr.io/x/y:1.2.3
refused "namespace hors périmètre (auth)" restart auth deploy/authentik-server
refused "namespace hors périmètre (immich)" scale immich deploy/immich-server 0
refused "Secret" delete "$ns1" secret/x
refused "PVC" delete "$ns1" pvc/data
refused "Service" patch "$ns1" svc/x '{}'
refused "verbe inconnu" exec "$ns1" deploy/web
refused "argument libre --force" delete "$ns1" pod/x --force
refused "argument --kubeconfig" restart "$ns1" deploy/web --kubeconfig=/tmp/x
refused "scale non entier" scale "$ns1" deploy/web -1
refused "scale d'un DaemonSet" scale "$ns1" ds/x 0
refused "suspend d'un Deployment" suspend "$ns1" deploy/web
refused "image latest" set-image "$ns1" deploy/web app=nginx:latest
refused "image sans tag" set-image "$ns1" deploy/web app=nginx
refused "image registry:port sans tag" set-image "$ns1" deploy/web app=registry.local:5000/x
expect_plan "image par digest" 'set image' set-image "$ns1" deploy/web app=ghcr.io/x/y@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
refused "patch non JSON" patch "$ns1" deploy/web 'spec: {}'
refused "patch json non tableau" patch "$ns1" deploy/web '{}' json
refused "nom invalide" delete "$ns1" pod/X_Y
refused "sans cible KIND/NAME" restart "$ns1" web
refused "apply depuis stdin" apply "$ns1" -
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: s}\n' >"$tmp/secret.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: d, namespace: auth}\n' >"$tmp/otherns.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: d}\n---\napiVersion: batch/v1\nkind: CronJob\nmetadata: {name: c, namespace: %s}\n' "$ns1" >"$tmp/ok.yaml"
refused "apply d'un Secret" apply "$ns1" "$tmp/secret.yaml"
refused "apply vers un autre namespace" apply "$ns1" "$tmp/otherns.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: d}\nspec: {template: {spec: {containers: [{name: c, image: "nginx"}]}}}\n' >"$tmp/unpinned.yaml"
refused "apply d'une image non épinglée" apply "$ns1" "$tmp/unpinned.yaml"
expect_plan "apply serveur-side" "apply --server-side --field-manager=agent-operator -n $ns1 -f" apply "$ns1" "$tmp/ok.yaml"
check "kubectl-ro.sh inchangé par PLT-237 (aucune écriture)" bash -c "! grep -qE '^\s*(apply|patch|delete|scale)\)' scripts/kubectl-ro.sh"

# 7. préflight : seuls les deux noms canoniques, et le bon secret est lu
out=$(KUBE_ACCESS_KUBECONFIG_SECRET=ROOT_KUBECONFIG bash -c 'source scripts/lib/kube-preflight.sh; _materialize_canonical_operator_kubeconfig' 2>&1 || true)
grep -q 'REASON=canonical_kubeconfig_secret_not_allowed' <<<"$out" && ok "préflight refuse un autre secret" || ko "préflight accepte un secret arbitraire"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/doppler" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$DOPPLER_STUB_LOG"
[ "$1" = me ] && exit 0
exit 1
EOF
chmod +x "$tmp/bin/doppler"
DOPPLER_STUB_LOG=$tmp/doppler.log PATH="$tmp/bin:$PATH" KUBE_ACCESS_KUBECONFIG_SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG \
  bash -c 'source scripts/lib/kube-preflight.sh; _materialize_canonical_operator_kubeconfig' >/dev/null 2>&1 || true
grep -q '^secrets get KUBERNETES_AGENT_OPERATOR_KUBECONFIG ' "$tmp/doppler.log" && ok "préflight lit KUBERNETES_AGENT_OPERATOR_KUBECONFIG" ||
  ko "préflight ne lit pas le secret agent"
: >"$tmp/doppler.log"
DOPPLER_STUB_LOG=$tmp/doppler.log PATH="$tmp/bin:$PATH" bash -c 'unset KUBE_ACCESS_KUBECONFIG_SECRET; source scripts/lib/kube-preflight.sh; _materialize_canonical_operator_kubeconfig' >/dev/null 2>&1 || true
grep -q '^secrets get KUBERNETES_OPERATOR_KUBECONFIG ' "$tmp/doppler.log" && ok "préflight : défaut opérateur inchangé" || ko "préflight : défaut opérateur modifié"

# 8. syntaxe
for s in scripts/kubectl-rw.sh scripts/agent-operator-token.sh scripts/lib/kube-preflight.sh; do check "bash -n $s" bash -n "$s"; done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck (warning)" shellcheck -S warning -x -P SCRIPTDIR scripts/kubectl-rw.sh scripts/agent-operator-token.sh tests/agent-guard/agent-operator-identity-test.sh
fi

if [ "$fails" -gt 0 ]; then echo "AGENT_OPERATOR_IDENTITY_TEST=FAIL ($fails)"; exit 1; fi
echo "AGENT_OPERATOR_IDENTITY_TEST=PASS"
