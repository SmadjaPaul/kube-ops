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
kyverno="$repo_root/k8s/infrastructure/security/policies/kyverno-policies.yaml"
gatekeeper="$repo_root/k8s/infrastructure/security/policies/gatekeeper-constraints.yaml"

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
if grep -Eiq 'ntfy|receiver:' "$prom_values"; then
  echo 'ERROR: Alertmanager-to-ntfy activation leaked into desired values' >&2
  exit 1
fi

yq -e '
  .kind == "RuntimePolicyQualification" and
  .spec.status == "not-executed" and
  .spec.approval == "required" and
  .spec.currentModes.kyverno == "Audit" and
  .spec.currentModes.gatekeeper == "dryrun" and
  (([.spec.cases[] | select(.expectedFinding == "none")] | length) >= 1) and
  (([.spec.cases[] | select(.expectedFinding == "violation")] | length) >= 3) and
  .spec.tenantIsolation.status == "not-executed"
' "$policy_fixture" >/dev/null
yq -e '.spec.validationFailureAction == "Audit"' "$kyverno" >/dev/null
yq -e '.spec.enforcementAction == "dryrun"' "$gatekeeper" >/dev/null

yq -e '
  .kind == "RecoveryQualification" and
  .spec.status == "not-executed" and
  .spec.approval == "required" and
  .spec.restoreTarget == "isolated" and
  .spec.productionTargetsExcluded == true and
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
