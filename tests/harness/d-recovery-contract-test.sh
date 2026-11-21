#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
alert_fixture="$repo_root/tests/fixtures/recovery/alertmanager-ntfy-e2e.yaml"
policy_fixture="$repo_root/tests/fixtures/recovery/security-policy-cases.yaml"
storage_fixture="$repo_root/tests/fixtures/recovery/storage-classification.yaml"
restore_fixture="$repo_root/tests/fixtures/recovery/cnpg-velero-restore.yaml"
restore_doc="$repo_root/website/docs/disaster/cnpg-velero-synthetic-restore.md"
alert_doc="$repo_root/docs/operations/homeops-observability-alerting.md"
eso_doc="$repo_root/docs/operations/e4-eso-orphans-acceptance.md"
prom_values="$repo_root/k8s/infrastructure/monitoring/prometheus-stack/values.yaml"
kyverno="$repo_root/k8s/infrastructure/security/policies/platform-baseline.yaml"

for file in "$alert_fixture" "$policy_fixture" "$storage_fixture" "$restore_fixture" "$restore_doc" "$alert_doc" "$eso_doc"; do
  test -f "$file" || { echo "ERROR: missing recovery contract file: $file" >&2; exit 1; }
done

yq -e '
  .kind == "AlertDeliveryQualification" and
  .spec.status == "not-executed" and
  .spec.approval == "required" and
  .spec.credentialsFileRequired == true and
  .spec.lifecycle[0] == "firing" and
  .spec.lifecycle[1] == "resolved" and
  .spec.deduplication.sameFingerprintMaxMessages == 1 and
  (.spec.assertions | length == 6)
' "$alert_fixture" >/dev/null
grep -F 'send_resolved' "$alert_doc" >/dev/null
grep -F 'firing' "$alert_doc" >/dev/null
grep -F 'resolved' "$alert_doc" >/dev/null
grep -F 'deduplicated' "$alert_doc" >/dev/null
grep -F 'unauthenticated publisher cannot publish' "$alert_doc" >/dev/null
# PLT-263 (kube-ops#1471, D-2026-11-13-02): the receivers are ACTIVE. This test
# protects the active shape instead of forbidding it: receiver URLs come only
# from Doppler-backed ExternalSecret files, never from values or plain Secrets.
alert_secrets="$repo_root/k8s/infrastructure/monitoring/prometheus-stack/alertmanager-secrets.yaml"
test -f "$alert_secrets" || { echo "ERROR: missing $alert_secrets" >&2; exit 1; }
am_check() {
  yq -e "$1" "$prom_values" >/dev/null ||
    { echo "ERROR: Alertmanager receivers not in the intended active shape: $2" >&2; exit 1; }
}
am_check '.alertmanager.config.receivers | map(.name) | contains(["healthchecks-watchdog", "ntfy-critical"])' receivers-present
am_check '[.alertmanager.config.route.routes[] | select(.receiver == "healthchecks-watchdog")] | length == 1' watchdog-route-single
am_check '[.alertmanager.config.route.routes[] | select(.receiver == "healthchecks-watchdog")] | .[0].matchers[0] == "alertname = Watchdog"' watchdog-route-matcher
am_check '[.alertmanager.config.route.routes[] | select(.receiver == "healthchecks-watchdog")] | .[0].repeat_interval | test("^([1-5]m|[0-9]+s)$")' watchdog-route-short-repeat
am_check '[.alertmanager.config.route.routes[] | select(.receiver == "ntfy-critical")] | length == 1' ntfy-route
am_check '[.alertmanager.config.receivers[] | select(.name == "ntfy-critical") | .webhook_configs[] | select(.send_resolved == true and .url_file == "/etc/alertmanager/secrets/alertmanager-ntfy-url/url")] | length == 1' ntfy-url-file-resolved
am_check '[.alertmanager.config.receivers[] | select(.name == "healthchecks-watchdog") | .webhook_configs[] | select(.url_file == "/etc/alertmanager/secrets/alertmanager-healthchecks-ping/url")] | length == 1' watchdog-url-file
am_check '[.alertmanager.config.receivers[].webhook_configs[]? | select(has("url"))] | length == 0' no-inline-url
am_check '.alertmanager.alertmanagerSpec.secrets | contains(["alertmanager-healthchecks-ping", "alertmanager-ntfy-url"])' secrets-mounted
if grep -Eiq 'hc-ping\.com|ntfy\.sh|https?://[^ ]*(ntfy|hc-ping)' "$prom_values"; then
  echo 'ERROR: Alertmanager receiver URL or token appears in values.yaml (must be an ExternalSecret file)' >&2
  exit 1
fi
yq -e '
  .kind == "ExternalSecret" and
  .spec.secretStoreRef.name == "doppler-cluster" and
  .spec.secretStoreRef.kind == "ClusterSecretStore" and
  (.spec.data | length == 1) and
  (.spec.data[0].remoteRef.key | test("^(HEALTHCHECKS_WATCHDOG_PING_URL|ALERTMANAGER_NTFY_URL)$"))
' "$alert_secrets" >/dev/null || { echo 'ERROR: Alertmanager ExternalSecret is not Doppler-backed as intended' >&2; exit 1; }
if [ "$(grep -c '^kind: ExternalSecret$' "$alert_secrets")" -ne 2 ] ||
  grep -Eq '^kind: Secret$|^[[:space:]]*(stringData|value):|property: value' "$alert_secrets"; then
  echo 'ERROR: alertmanager-secrets.yaml must hold exactly two ExternalSecrets and no plaintext Secret material' >&2
  exit 1
fi

yq -e '
  .kind == "RuntimePolicyQualification" and
  .spec.status == "not-executed" and
  .spec.approval == "required" and
  .spec.currentModes.kyverno == "Audit" and
  (([.spec.cases[] | select(.expectedFinding == "none")] | length) >= 1) and
  (([.spec.cases[] | select(.expectedFinding == "violation")] | length) >= 3) and
  .spec.tenantIsolation.status == "not-executed"
' "$policy_fixture" >/dev/null
# Socle Kyverno : ValidatingPolicy, toutes en Audit (aucune admission refusee tant que la qualification runtime n'est pas faite).
[ "$(yq 'select(.kind == "ValidatingPolicy") | select((.spec.validationActions | join(",")) != "Audit") | .metadata.name' "$kyverno" | grep -c .)" -eq 0 ] &&
  [ "$(yq 'select(.kind == "ValidatingPolicy") | .metadata.name' "$kyverno" | grep -c .)" -ge 1 ] || {
  echo 'ERROR: platform-baseline.yaml must hold only Audit-mode ValidatingPolicy' >&2
  exit 1
}

yq -e '
  .kind == "RecoveryQualification" and
  .spec.status == "not-executed" and
  .spec.approval == "required" and
  .spec.authorization.scope == "synthetic-only" and
  .spec.authorization.operatorApprovalRequired == true and
  .spec.authorization.autonomousExecutionAllowed == true and
  .spec.authorization.secondOperatorRequired == false and
  .spec.authorization.independentStopRequired == true and
  .spec.authorization.hardDeadlineRequired == true and
  .spec.restoreTarget == "isolated" and
  .spec.productionTargetsExcluded == true and
  .spec.applicationRestore.approvalRequired == true and
  .spec.applicationRestore.productionTargetsExcluded == true and
  .spec.network.enforcement == "cilium" and
  .spec.network.defaultDenyIngress == true and
  .spec.network.defaultDenyEgress == true and
  .spec.network.productionNamespacesDenied == true and
  .spec.network.externalServicesDenied == true and
  .spec.cnpg.sentinelCheck == "row-count-and-checksum" and
  .spec.veleroKopia.expectedPodVolumeBackups == 2 and
  .spec.veleroKopia.expectedPodVolumeRestores == 2 and
  .spec.cleanup.approvalRequired == true and
  .spec.cleanup.deleteProductionObjects == false
' "$restore_fixture" >/dev/null

yq -e '
  .kind == "StorageRecoveryInventory" and
  .spec.deletionAuthorized == false and
  .spec.longhorn.healthyVolumes == 70 and
  .spec.longhorn.detachedOrUnknownVolumes == 28 and
  .spec.backupAudit.uncoveredDrillPvcs == 17 and
  ([.spec.classifications[] | select(.action | test("retain"))] | length) >= 3
' "$storage_fixture" >/dev/null

grep -F 'RESTORE_PROOF` remains `NOT_PROVEN`' "$restore_doc" >/dev/null
grep -F 'bootstrap.recovery' "$restore_doc" >/dev/null
grep -F 'externalClusters' "$restore_doc" >/dev/null
grep -F 'PodVolumeBackups' "$restore_doc" >/dev/null
grep -F 'PodVolumeRestores' "$restore_doc" >/dev/null
grep -F 'RPO' "$restore_doc" >/dev/null
grep -F 'RTO' "$restore_doc" >/dev/null
grep -F 'Owner role and approval path' "$eso_doc" >/dev/null
if grep -Eiq 'Doppler[^\n]*(token|password|secret)[[:space:]]*[:=]' "$eso_doc"; then
  echo 'ERROR: Doppler credential material appears in the owner inventory' >&2
  exit 1
fi

printf '%s\n' 'D_RECOVERY_CONTRACT_TEST=PASS'
