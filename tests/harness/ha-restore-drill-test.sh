#!/usr/bin/env bash
# PRD-76 : contrat du drill de restauration Velero de Home Assistant (sans cluster).
# Règle pods de restore-pvc-isolation appliquée comme Velero 1.18.2, miroir des
# deux ValidatingAdmissionPolicy, vérificateur sur faux /config, Job sur fausse API.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRILL="$ROOT/k8s/infrastructure/controllers/velero-ha-restore-drill"
MOD="$ROOT/k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml"
STS="$ROOT/k8s/applications/automation/hassio/statefulset.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

yq -r '.data["resource-modifier.yaml"]' "$MOD" >"$tmp/rules.yaml"
yq -o=json '.' "$tmp/rules.yaml" >"$tmp/rules.json"
image="$(yq -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "home-assistant") | .image' "$STS")"
HA_DRILL_RULES_JSON="$tmp/rules.json" HA_DRILL_RULES_YAML="$tmp/rules.yaml" HA_DRILL_HA_IMAGE="$image" \
  python3 -I "$ROOT/tests/harness/ha-restore-drill-test.py"

cj="$DRILL/cronjob.yaml"
[ "$(yq -r '.spec.suspend' "$cj")" = true ] || fail "CronJob ha-restore-drill doit être suspendu"
[ "$(yq -r '.spec.jobTemplate.spec.backoffLimit' "$cj")" = 0 ] || fail "backoffLimit 0 attendu"
[ "$(yq -r '.spec.jobTemplate.spec.activeDeadlineSeconds' "$cj")" -gt 1500 ] || fail "activeDeadlineSeconds > deadline interne + nettoyage"
grep -q 'DEADLINE = int(os.environ.get("DRILL_DEADLINE_SECONDS", "1200"))' "$DRILL/ha-restore-drill.py" || fail "deadline interne 1200 s attendue"
grep -q ttlSecondsAfterFinished "$cj" && fail "pas de ttlSecondsAfterFinished (journaux à lire)"
[ "$(yq -r 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$DRILL/namespace.yaml")" = baseline ] ||
  fail "namespace de test : Pod Security baseline attendu"
[ "$(yq -r 'select(.kind == "CiliumNetworkPolicy") | .spec.egressDeny[0].toEntities[0]' "$DRILL/namespace.yaml")" = all ] ||
  fail "namespace de test : egressDeny all attendu"
# RBAC : aucun verbe d'écriture hors Restore (create) et nettoyage du namespace de test.
writes="$(yq -o=json -I=0 'select(.kind == "Role" or .kind == "ClusterRole") | {"ns": (.metadata.namespace // "cluster"), "r": .rules[]} |
  select(.r.verbs[] | test("^(create|update|patch|delete|deletecollection|\\*)$"))' "$DRILL/rbac.yaml" | jq -c '[.ns, .r.resources, .r.verbs]' | sort -u)"
expected='["home-assistant-restore-test",["pods","persistentvolumeclaims"],["get","list","delete"]]
["velero",["restores"],["create","get"]]'
[ "$writes" = "$expected" ] || fail "RBAC du drill : écritures inattendues : $writes"
grep -q 'resources: \["\*"\]' "$DRILL/admission.yaml" || fail "restore-guard doit couvrir toutes les ressources velero.io"
if command -v kustomize >/dev/null 2>&1; then
  kustomize build "$DRILL" | grep -q 'name: ha-restore-drill-script' || fail "ConfigMap du script absente"
  grep -qx -- '- velero-ha-restore-drill' "$ROOT/k8s/infrastructure/controllers/kustomization.yaml" || fail "dossier non importé"
fi
echo "HA_RESTORE_DRILL_TEST=PASS"
