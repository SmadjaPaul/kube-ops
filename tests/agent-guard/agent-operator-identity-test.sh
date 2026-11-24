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
CJR=$DIR/cronjob-run.tsv
CJR_RBAC=k8s/applications/platform/agent-operator-access/cronjob-run.yaml
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
check "app agent-operator-access (descripteur) et agregat du domaine platform" grep -qx '  - agent-operator-access' k8s/applications/platform/kustomization.yaml
check "descripteur argocd-app.yaml de agent-operator-access" test -f k8s/applications/platform/agent-operator-access/argocd-app.yaml

# 4. RBAC : jamais de Secret, d'escalade, d'exec, de PVC/PV en écriture
rules=$(yq -o=json -I=0 'select(.kind == "ClusterRole" or .kind == "Role") | {"n": .metadata.name, "r": .rules}' "$RBAC" | jq -c '.n as $n | .r[] | . + {role: $n}')
# Seule exception à la règle pods/(exec|attach|portforward) : la règle exacte du Role
# agent-operator-hubble-relay (PRD-88), vérifiée en 4c.
HUBBLE_RULE='{"apiGroups":[""],"resources":["pods/portforward"],"verbs":["create"],"role":"agent-operator-hubble-relay"}'
violations=$(jq -c --argjson hr "$HUBBLE_RULE" 'select(. != $hr) | select(
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
# 4b. proxy de lecture Prometheus/Loki : Role monitoring, get seul, deux services nommés
MQ='select(.kind == "Role" and .metadata.name == "agent-operator-monitoring-query" and .metadata.namespace == "monitoring")'
check "rbac.yaml : deux Roles exactement (hubble-relay dans kube-system, monitoring-query dans monitoring)" \
  test "$(yq -N 'select(.kind == "Role") | .metadata.namespace + "/" + .metadata.name' "$RBAC" | sort | tr '\n' ' ')" = "kube-system/agent-operator-hubble-relay monitoring/agent-operator-monitoring-query "
check "monitoring-query : une règle, get sur services/proxy seulement" \
  test "$(yq -N -o=json -I=0 "$MQ | [.rules[] | {\"r\": .resources, \"v\": .verbs, \"g\": .apiGroups}]" "$RBAC" | grep -vx '\[\]')" = '[{"r":["services/proxy"],"v":["get"],"g":[""]}]'
check "monitoring-query : resourceNames = Prometheus et loki-gateway" \
  test "$(yq -N -o=json -I=0 "$MQ | .rules[0].resourceNames" "$RBAC")" = '["kube-prometheus-stack-prometheus:9090","loki-gateway:80"]'
check "monitoring-query : RoleBinding limité au ServiceAccount agent-operator" \
  test "$(yq -N -o=json -I=0 'select(.kind == "RoleBinding" and .metadata.namespace == "monitoring") | [.metadata.namespace, .roleRef.kind, .roleRef.name, .subjects[0].name, .subjects[0].namespace, (.subjects | length)]' "$RBAC" | grep -vx '\[\]')" = '["monitoring","Role","agent-operator-monitoring-query","agent-operator","agent-operator",1]'
check "rbac.yaml : deux RoleBindings exactement (kube-system, monitoring)" \
  test "$(yq -N 'select(.kind == "RoleBinding") | .metadata.namespace' "$RBAC" | sort | tr '\n' ' ')" = "kube-system monitoring "
proxy_bad=$(jq -c 'select((.resources // []) | map(test("/proxy$")) | any) | select(.role != "agent-operator-monitoring-query" or ((.resourceNames // []) | length) == 0 or (.verbs != ["get"]))' <<<"$rules")
[ -z "$proxy_bad" ] && ok "RBAC : services/proxy seulement via monitoring-query, nommé, get" || ko "proxy hors monitoring-query ou trop large : $proxy_bad"
check "can-i de agent-operator-token.sh : proxy Prometheus/Loki, positif et négatif" bash -c \
  "grep -q 'can yes get services/kube-prometheus-stack-prometheus:9090 --subresource=proxy -n monitoring' scripts/agent-operator-token.sh \
   && grep -q 'can yes get services/loki-gateway:80 --subresource=proxy -n monitoring' scripts/agent-operator-token.sh \
   && grep -q 'can no create services/kube-prometheus-stack-prometheus:9090 --subresource=proxy -n monitoring' scripts/agent-operator-token.sh \
   && grep -q 'can no patch services/kube-prometheus-stack-prometheus:9090 --subresource=proxy -n monitoring' scripts/agent-operator-token.sh \
   && grep -q 'can no delete services/kube-prometheus-stack-prometheus:9090 --subresource=proxy -n monitoring' scripts/agent-operator-token.sh \
   && grep -q 'can no get secrets -n monitoring' scripts/agent-operator-token.sh"
# 4c. PRD-88 : port-forward Hubble = Role kube-system, create seul sur pods/portforward,
# lié au seul ServiceAccount agent-operator ; nulle part ailleurs (homelab, OKE, accès par namespace).
HR='select(.kind == "Role" and .metadata.name == "agent-operator-hubble-relay" and .metadata.namespace == "kube-system")'
check "hubble-relay : une règle, create sur pods/portforward seulement, sans resourceNames ni autre verbe" \
  test "$(yq -N -o=json -I=0 "$HR | .rules" "$RBAC" | grep -vx '\[\]')" = '[{"apiGroups":[""],"resources":["pods/portforward"],"verbs":["create"]}]'
check "hubble-relay : RoleBinding limité au ServiceAccount agent-operator" \
  test "$(yq -N -o=json -I=0 'select(.kind == "RoleBinding" and .metadata.namespace == "kube-system") | [.metadata.name, .roleRef.kind, .roleRef.name, .subjects[0].kind, .subjects[0].name, .subjects[0].namespace, (.subjects | length)]' "$RBAC" | grep -vx '\[\]')" = '["agent-operator-hubble-relay","Role","agent-operator-hubble-relay","ServiceAccount","agent-operator","agent-operator",1]'
pf_files=$(grep -rlE '^[^#]*pods/(portforward|exec|attach)' "$RBAC" k8s/applications/platform/agent-operator-access k8s/clusters/oracle-a1/agent-operator | sort | tr '\n' ' ')
[ "$pf_files" = "$RBAC " ] && ok "pods/portforward : rbac.yaml seulement (ni accès par namespace, ni OKE), jamais exec/attach" ||
  ko "pods/portforward|exec|attach hors rbac.yaml : $pf_files"
check "rbac.yaml : aucun exec/attach" bash -c "! grep -qE '^[^#]*pods/(exec|attach)' '$RBAC'"
crb=$(yq -N 'select(.kind == "ClusterRoleBinding") | .roleRef.name' "$RBAC" | sort | tr '\n' ' ')
[ "$crb" = "agent-operator-cluster-read view " ] && ok "ClusterRoleBindings = view + cluster-read" || ko "ClusterRoleBindings inattendus : $crb"
check "ServiceAccount sans montage de jeton" \
  test "$(yq -N 'select(.kind == "ServiceAccount") | .automountServiceAccountToken' "$DIR/identity.yaml")" = false
check "namespace agent-operator protégé" \
  test "$(yq -N 'select(.kind == "Namespace") | .metadata.labels["smadja.dev/agent-protected"]' "$DIR/identity.yaml")" = true
if grep -rqE 'kind: ClusterRoleBinding' k8s/applications/platform/agent-operator-access; then ko "ClusterRoleBinding dans agent-operator-access"; fi

# 5. policy : fail-closed, Deny, limitée à l'identité exacte
check "policies failurePolicy Fail (toutes)" test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .spec.failurePolicy' "$VAP" | sort -u)" = Fail
check "policy agent-operator-guard failurePolicy Fail" test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "agent-operator-guard") | .spec.failurePolicy' "$VAP")" = Fail
check "bindings Deny (tous)" test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions | join(",")' "$VAP" | sort -u)" = Deny
check "binding agent-operator-guard Deny, sans paramètre" test "$(yq -N -o=json -I=0 'select(.kind == "ValidatingAdmissionPolicyBinding" and .metadata.name == "agent-operator-guard") | [.spec.policyName, (.spec.validationActions | join(",")), (.spec.paramRef // "none")]' "$VAP" | grep -vx '\[\]')" = '["agent-operator-guard","Deny","none"]'
check "matchCondition = identité agent exacte" grep -q "request.userInfo.username == 'system:serviceaccount:agent-operator:agent-operator'" "$VAP"
check "policy : exemption CONNECT limitée aux deux services proxy monitoring" bash -c \
  "grep -q \"request.operation == 'CONNECT'\" '$VAP' && grep -q \"request.namespace == 'monitoring'\" '$VAP' \
   && grep -q \"request.name in \\['kube-prometheus-stack-prometheus:9090', 'loki-gateway:80'\\]\" '$VAP' \
   && test \"\$(yq -N 'select(.kind == \"ValidatingAdmissionPolicy\" and .metadata.name == \"agent-operator-guard\") | .spec.matchConditions | length' '$VAP')\" = 3"
HPF=$(yq -N 'select(.metadata.name == "agent-operator-guard" and .kind == "ValidatingAdmissionPolicy") | .spec.matchConditions[] | select(.name == "not-hubble-relay-portforward") | .expression' "$VAP")
hpf_ok=1
for frag in "!(request.operation == 'CONNECT'" "request.resource.resource == 'pods'" "request.subResource == 'portforward'" \
  "request.namespace == 'kube-system'" "request.name.matches('^hubble-relay-[a-z0-9]{6,10}-[a-z0-9]{5}\$')"; do
  grep -qF "$frag" <<<"$HPF" || { hpf_ok=0; ko "policy : exemption port-forward sans '$frag'"; }
done
[ "$hpf_ok" = 1 ] && ok "policy : exemption CONNECT pods/portforward limitée au pod hubble-relay de kube-system"
check "policy : pas de sous-ressource scale admise" bash -c "! grep -q \"/scale'\" '$VAP'"
for msg in agent-protected 'cnpg.io/cluster' persistentVolumeClaimRetentionPolicy secretKeyRef secretRef serviceAccountName hostNetwork \
  persistentVolumeClaim oldCarriesCredentials 'variables.newSpec == variables.oldSpec' oldPrivileged; do
  grep -q "$msg" "$VAP" || ko "policy sans contrôle $msg"
done
ok "policy : contrôles protégé/CNPG/rétention PVC/Secret/SA/hôte présents"
check "policy : gel des credentials dans l'expression UPDATE" \
  grep -qF '!variables.oldCarriesCredentials || variables.newSpec == variables.oldSpec' "$VAP"
check "policy : PVC refusées à la création" grep -qF 'has(v.persistentVolumeClaim) || has(v.ephemeral)' "$VAP"

# 5b. PRD-88 : Jobs manuels (run-cronjob). Une liste (cronjob-run.tsv) = variable manualRuns
# = bindings de agent-operator-cronjob-run = Roles par namespace ; disjointe de scope.tsv.
pairs=$(grep -vE '^#|^$' "$CJR" | cut -f1,2 | tr '\t' '/' | sort)
[ -n "$pairs" ] || ko "cronjob-run.tsv vide"
mr=$(yq -N 'select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "agent-operator-guard") | .spec.variables[] | select(.name == "manualRuns") | .expression' "$VAP" |
  grep -oE "'[a-z0-9/-]+'" | tr -d "'" | sort)
[ "$mr" = "$pairs" ] && ok "policy manualRuns = cronjob-run.tsv" || ko "policy manualRuns ≠ cronjob-run.tsv"
CP='select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "agent-operator-cronjob-run")'
binds=$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "agent-operator-cronjob-run") |
  select(.metadata.name == "agent-operator-cronjob-run-" + .spec.paramRef.name and (.spec.validationActions | join(",")) == "Deny" and
  .spec.paramRef.parameterNotFoundAction == "Deny" and
  .spec.matchResources.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == .spec.paramRef.namespace) |
  .spec.paramRef.namespace + "/" + .spec.paramRef.name' "$VAP" | sort)
[ "$binds" = "$pairs" ] && ok "bindings cronjob-run (Deny, paramètre obligatoire, namespace du CronJob) = cronjob-run.tsv" ||
  ko "bindings cronjob-run ≠ cronjob-run.tsv : $binds"
check "bindings cronjob-run : aucun autre binding de la policy" \
  test "$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "agent-operator-cronjob-run") | .metadata.name' "$VAP" | wc -l | tr -d ' ')" = "$(wc -l <<<"$pairs" | tr -d ' ')"
check "policy cronjob-run : Fail, paramètre CronJob, CREATE de jobs, identité agent exacte" \
  test "$(yq -N -o=json -I=0 "$CP | [.spec.failurePolicy, .spec.paramKind.apiVersion, .spec.paramKind.kind, .spec.matchConstraints.resourceRules[0].operations, .spec.matchConstraints.resourceRules[0].resources, .spec.matchConditions[0].expression]" "$VAP" | grep -vx '\[\]')" = \
  "[\"Fail\",\"batch/v1\",\"CronJob\",[\"CREATE\"],[\"jobs\"],\"request.userInfo.username == 'system:serviceaccount:agent-operator:agent-operator'\"]"
for frag in 'object.spec.template.spec == params.spec.jobTemplate.spec.template.spec' 'object.spec.manualSelector' \
  'variables.jobAnnotations == variables.cronAnnotations' 'variables.cronLabels.all(k, k in variables.jobLabels' \
  "matches('^' + params.metadata.name + '-manual-[0-9]{14}\$')"; do
  yq -N "$CP | .spec" "$VAP" | grep -qF "$frag" || ko "policy cronjob-run sans contrôle '$frag'"
done
ok "policy cronjob-run : pod spec, labels, annotations et manualSelector contrôlés"
check "garde : manualRun limité à la création d'un Job nommé <cronjob>-manual-<14 chiffres>" \
  grep -qF "request.operation == 'CREATE' && variables.target == 'batch/jobs' &&" "$VAP"
check "garde : manualRun utilisé seulement par la règle de namespace et l'exemption de création" \
  test "$(grep -c 'variables.manualRun\b' "$VAP")" = 2
cjr_ns=$(cut -d/ -f1 <<<"$pairs" | sort -u)
for ns in $cjr_ns; do grep -qxF "$ns" <<<"$scope" && ko "namespace run-cronjob aussi dans scope.tsv : $ns"; done
ok "namespaces run-cronjob hors scope.tsv"
for p in $pairs; do
  f=$(grep -rlE "^  name: ${p#*/}\$" k8s/applications | xargs grep -l '^kind: CronJob' 2>/dev/null | head -1 || true)
  [ -n "$f" ] && yq -N "select(.kind == \"CronJob\" and .metadata.name == \"${p#*/}\") | .metadata.namespace // \"\"" "$f" | grep -qxE "(${p%/*})?" ||
    ko "CronJob $p absent de Git (k8s/applications)"
done
ok "chaque CronJob de cronjob-run.tsv est déclaré dans Git"
check "Roles cronjob-run : un par namespace de cronjob-run.tsv" \
  test "$(yq -N 'select(.kind == "Role" and .metadata.name == "agent-operator-cronjob-run") | .metadata.namespace' "$CJR_RBAC" | sort)" = "$cjr_ns"
check "Roles cronjob-run : create sur jobs seulement" \
  test "$(yq -N -o=json -I=0 'select(.kind == "Role") | .rules' "$CJR_RBAC" | grep -vx 'null' | sort -u)" = '[{"apiGroups":["batch"],"resources":["jobs"],"verbs":["create"]}]'
check "cronjob-run.yaml : Roles et RoleBindings seulement, aucun autre objet" \
  test "$(yq -N '.kind' "$CJR_RBAC" | sort -u | tr '\n' ' ')" = "Role RoleBinding "
check "RoleBindings cronjob-run : rôle et sujet exacts" \
  test "$(yq -N -o=json -I=0 'select(.kind == "RoleBinding") | [.metadata.name, .roleRef.kind, .roleRef.name, .subjects[0].kind, .subjects[0].name, .subjects[0].namespace, (.subjects | length)]' "$CJR_RBAC" | grep -vx '\[\]' | sort -u)" = \
  '["agent-operator-cronjob-run","Role","agent-operator-cronjob-run","ServiceAccount","agent-operator","agent-operator",1]'
check "RoleBindings cronjob-run : un par namespace" \
  test "$(yq -N 'select(.kind == "RoleBinding") | .metadata.namespace' "$CJR_RBAC" | sort)" = "$cjr_ns"
check "agent-operator-access importe cronjob-run.yaml" grep -qx '  - cronjob-run.yaml' k8s/applications/platform/agent-operator-access/kustomization.yaml

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
expect_plan "restart = patch restartedAt" "patch deployment/web -n $ns1 --type=merge -p .*kubectl.kubernetes.io/restartedAt" restart "$ns1" deployment/web
expect_plan "undo" "rollout undo deployment/web -n $ns1\$" undo "$ns1" deployment/web
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
printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: {name: c, labels: {image: backend}}\nspec: {jobTemplate: {spec: {template: {spec: {initContainers: [{name: i, image: "busybox"}], containers: [{name: c, image: "busybox:1.37"}]}}}}}\n' >"$tmp/cj-init.yaml"
refused "apply : initContainer CronJob non épinglé" apply "$ns1" "$tmp/cj-init.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: d, labels: {image: backend}}\nspec: {template: {spec: {containers: [{name: c, image: "busybox:1.37"}]}}}\n' >"$tmp/label-image.yaml"
expect_plan "apply : label image ignoré" "apply --server-side" apply "$ns1" "$tmp/label-image.yaml"
expect_plan "apply serveur-side" "apply --server-side --field-manager=agent-operator -n $ns1 -f" apply "$ns1" "$tmp/ok.yaml"
# 6b. PRD-88 : run-cronjob, couples de cronjob-run.tsv seulement, nom de Job imposé
for p in $pairs; do
  expect_plan "run-cronjob $p" "^KUBECTL_RW_PLAN=kubectl create job ${p#*/}-manual-[0-9]{14} -n ${p%/*} --from=cronjob/${p#*/}\$" run-cronjob "${p%/*}" "cronjob/${p#*/}"
done
expect_plan "run-cronjob dry-run serveur" '--from=cronjob/ma-reconcile-plan --dry-run=server$' --dry-run run-cronjob music-assistant cj/ma-reconcile-plan
refused "run-cronjob hors liste" run-cronjob music-assistant cronjob/other
refused "run-cronjob : couple namespace/cronjob croisé" run-cronjob home-assistant cronjob/ma-reconcile-plan
refused "run-cronjob dans un namespace de scope.tsv" run-cronjob "$ns1" cronjob/backup
refused "run-cronjob : argument libre" run-cronjob home-assistant cronjob/ha-mcp-token-rotate --from=cronjob/x
refused "run-cronjob : nom de Job fourni" run-cronjob home-assistant cronjob/ha-mcp-token-rotate my-job
refused "run-cronjob : type deployment" run-cronjob home-assistant deploy/ha-mcp-token-rotate
refused "run-cronjob : type job" run-cronjob home-assistant job/ha-mcp-token-rotate
refused "home-assistant : restart (hors scope.tsv)" restart home-assistant deploy/home-assistant
refused "home-assistant : delete job (hors scope.tsv)" delete home-assistant job/ha-mcp-token-rotate-1
refused "music-assistant : resume du CronJob apply (hors scope.tsv)" resume music-assistant cj/ma-reconcile-apply
refused "music-assistant : apply (hors scope.tsv)" apply music-assistant "$tmp/ok.yaml"
check "can-i de agent-operator-token.sh : port-forward Hubble et Jobs manuels, positif et négatif" bash -c \
  "grep -q 'can yes create pods/portforward -n kube-system' scripts/agent-operator-token.sh \
   && grep -q 'can no create pods/portforward -n media' scripts/agent-operator-token.sh \
   && grep -q 'can yes create jobs -n home-assistant' scripts/agent-operator-token.sh \
   && grep -q 'can no delete jobs -n home-assistant' scripts/agent-operator-token.sh \
   && grep -q 'can no get secrets -n home-assistant' scripts/agent-operator-token.sh"

# 6c. PRD-88 : kubectl-ro.sh hubble, liste blanche (mode plan : aucun accès cluster)
RO=scripts/kubectl-ro.sh
ro_refused() { # ro_refused DESC ARGS... : doit sortir 64
  local d=$1 rc=0
  shift
  KUBECTL_RO_HUBBLE_PLAN=1 bash "$RO" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 64 ] && ok "ro refuse : $d" || ko "ro accepte : $d (rc=$rc)"
}
ro_plan() { # ro_plan DESC MOTIF ARGS...
  local d=$1 pat=$2 out
  shift 2
  out=$(KUBECTL_RO_HUBBLE_PLAN=1 bash "$RO" "$@" 2>/dev/null) && grep -qE -- "$pat" <<<"$out" && ok "ro plan : $d" || ko "ro plan : $d => ${out:-refus}"
}
ro_plan "hubble status" '^KUBECTL_RO_HUBBLE_PLAN=hubble --server 127.0.0.1:<port> status$' hubble status
ro_plan "hubble observe filtres" 'observe --namespace home-assistant --to-ip 10.0.20.60 --to-port 8123 --last 50 --output json$' \
  hubble observe -n home-assistant --to-ip 10.0.20.60 --to-port 8123 --last 50 -o json
ro_plan "hubble observe --opt=valeur et --not" 'observe --namespace music-assistant --verdict DROPPED --not --label app=x$' \
  hubble observe --namespace=music-assistant --verdict DROPPED --not -l app=x
for bad in "--follow" "-f" "--all" "--first 5" "--server x:1" "-P" "--port-forward" "--port-forward-port 1" "--tls" \
  "--tls-allow-insecure" "--config /dev/null" "--kubeconfig=/x" "--kube-context x" "--basic-auth-username x" "--input-file /x" \
  "--debug" "--last 1001" "--last 0" "--last x" "--verdict FOO" "-o yaml" "--namespace" "--namespace --last" "--not=true" \
  "--pod a;b" "--pod \$(id)" "x" "-n=x"; do
  # shellcheck disable=SC2086
  ro_refused "hubble observe $bad" hubble observe $bad
done
ro_refused "hubble : sous-commande inconnue" hubble list nodes
ro_refused "hubble status avec option" hubble status --server x:1
ro_refused "hubble sans sous-commande" hubble
ro_refused "hubble sur oracle-a1" --cluster oracle-a1 hubble status
check "kubectl-ro : port-forward seulement vers kube-system/svc/hubble-relay, 127.0.0.1" \
  test "$(grep -cE '^[^#]*kubectl port-forward' "$RO")" = 1
check "kubectl-ro : port-forward borné (namespace, service, adresse)" \
  grep -qF 'kubectl port-forward -n kube-system svc/hubble-relay --address 127.0.0.1 :80' "$RO"
check "kubectl-ro : CLI hubble sans environnement ni configuration héritée" grep -qF 'env -i PATH="$PATH" HOME="$hubble_home" hubble --server "127.0.0.1:$port"' "$RO"
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

# 7b. PLT-257 : sélecteur --cluster (lecture seule sur OKE)
check "kubectl-ro --cluster inconnu refusé" bash -c "bash scripts/kubectl-ro.sh --cluster prod get ns 2>&1 | grep -q 'inconnu'"
check "kubectl-ro : --cluster hors tête refusé" bash -c "bash scripts/kubectl-ro.sh get ns --cluster oracle-a1 2>&1 | grep -q 'uniquement de kube-preflight'"
check "kubectl-rw --cluster refusé (OKE en lecture seule)" bash -c "bash scripts/kubectl-rw.sh --cluster oracle-a1 patch a b c 2>&1 | grep -q 'lecture seule'"
check "RBAC OKE : verbes get/list/watch seulement" bash -c "! grep 'verbs:' k8s/clusters/oracle-a1/agent-operator/rbac.yaml | grep -vqE 'verbs: \\[get, list(, watch)?\\]' && ! grep -qE '^[^#]*[ ,[](secrets|pods/exec|serviceaccounts/token)[],]' k8s/clusters/oracle-a1/agent-operator/rbac.yaml"

# 7c. PLT-257 : normalisation de can-i (suffixe OKE)
# shellcheck source=scripts/lib/kube-can-i.sh
source scripts/lib/kube-can-i.sh
can_case() { # can_case LIBELLÉ ATTENDU ENTRÉE
  local got
  got=$(printf '%b' "$3" | kube_can_i_answer)
  if [ "$got" = "$2" ]; then ok "can-i : $1"; else ko "can-i : $1 (obtenu '$got', attendu '$2')"; fi
}
can_case "suffixe OKE no" no 'no - . Opc-Request-Id: <nil>\n'
can_case "no exact" no 'no\n'
can_case "yes exact" yes 'yes\n'
can_case "yes avec suffixe" yes 'yes - reason\n'
can_case "sortie vide refusée" "" ''
can_case "ligne vide refusée" "" '\n\n'
can_case "valeur inconnue refusée" "" 'maybe\n'
can_case "préfixe de mot refusé" "" 'yesterday\n'
can_case "casse refusée" "" 'Yes\n'
can_case "erreur refusée" "" 'error: forbidden\n'
can_case "premier mot seulement (no puis yes)" no 'no\nyes\n'

# 7b. serveur OKE repris de la session admin : adresse privee du VCN 10.0.0.0/16 seulement, pas d'IP en dur
# shellcheck source=../../scripts/lib/oke-api-server.sh
source scripts/lib/oke-api-server.sh
srv_case() { # srv_case LIBELLE ATTENDU(0|1) URL
  if oke_api_server_valid "$3"; then got=0; else got=1; fi
  if [ "$got" = "$2" ]; then ok "serveur OKE : $1"; else ko "serveur OKE : $1 (obtenu $got, attendu $2)"; fi
}
srv_case "IP privee du VCN" 0 "https://10.0.2.3:6443"
srv_case "autre IP du VCN" 0 "https://10.0.2.65:6443"
srv_case "sans port" 0 "https://10.0.1.7"
srv_case "http refuse" 1 "http://10.0.2.3:6443"
srv_case "IP publique refusee" 1 "https://203.0.113.10:6443"
srv_case "autre reseau prive refuse" 1 "https://10.1.2.3:6443"
srv_case "LAN 192.168 refuse" 1 "https://192.168.1.10:6443"
srv_case "octet hors plage refuse" 1 "https://10.0.2.300:6443"
srv_case "nom DNS refuse" 1 "https://oke.example.com:6443"
srv_case "chemin refuse" 1 "https://10.0.2.3:6443/evil"
srv_case "vide refuse" 1 ""
check "plus d'IP API codee en dur dans les scripts d'acces OKE" bash -c '! grep -nE "10\.0\.2\.[0-9]" scripts/kubectl-ro.sh scripts/agent-operator-oke-token.sh'

# 8. syntaxe
for s in scripts/kubectl-rw.sh scripts/agent-operator-token.sh scripts/agent-operator-oke-token.sh scripts/lib/oke-api-server.sh scripts/lib/kube-can-i.sh scripts/kubectl-ro.sh scripts/lib/kube-preflight.sh; do check "bash -n $s" bash -n "$s"; done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck (warning)" shellcheck -S warning -x -P SCRIPTDIR scripts/kubectl-rw.sh scripts/agent-operator-token.sh tests/agent-guard/agent-operator-identity-test.sh
fi

if [ "$fails" -gt 0 ]; then echo "AGENT_OPERATOR_IDENTITY_TEST=FAIL ($fails)"; exit 1; fi
echo "AGENT_OPERATOR_IDENTITY_TEST=PASS"
