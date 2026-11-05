#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/backup-audit"
output="$(mktemp)"
positive_dir="$(mktemp -d)"
negative_dir="$(mktemp -d)"
cnpg_negative_dir="$(mktemp -d)"
longhorn_dir="$(mktemp -d)"
selector_dir="$(mktemp -d)"
fsb_dir="$(mktemp -d)"
recovery_label_dir="$(mktemp -d)"
stale_evidence_dir="$(mktemp -d)"
policy_dir="$(mktemp -d)"
stale_policy_dir="$(mktemp -d)"
tmp_json="$longhorn_dir/mutation.tmp.json"
trap 'rm -f "$output"; rm -rf "$positive_dir" "$negative_dir" "$cnpg_negative_dir" "$longhorn_dir" "$selector_dir" "$fsb_dir" "$recovery_label_dir" "$stale_evidence_dir" "$policy_dir" "$stale_policy_dir"' EXIT

qualification_evidence="$repo_root/docs/operations/dr-restore-evidence-2026-10-20.json"
jq -e '
  . as $root |
  [.items[] | select(.kind == "Longhorn/S3" and ((.pvc.uid // "") as $uid |
    $uid == "a09c12b9-203b-4610-8558-1e6f8088c18c" or
    $uid == "c36eea64-f347-46af-88a2-46ab620575b0" or
    $uid == "06fc6da9-bf5d-4538-b8a3-42fc735956c0"))] | length == 3 and
  ([$root.items[] | select(.id == "longhorn-s3-immich-redis-20261020")][0] |
    .restoreVerified == true and .aofIntegrityVerified == true and
    .redisCopyRecoveryVerified == true and .applicationRecoveryVerified == false) and
  ([$root.items[] | select(.id == "longhorn-s3-mastra-active-20261020" or .id == "longhorn-s3-mastra-suspended-20261020")] |
    all(.[]; .restoreVerified == true and .applicationRecoveryVerified == false))
' "$qualification_evidence" >/dev/null

cp -R "$fixture_dir/." "$positive_dir/"
jq '.producedAt = (now | todateiso8601)' "$positive_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$positive_dir/restore-evidence.json"
BACKUP_AUDIT_INPUT_DIR="$positive_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output"
test ! -e "$fixture_dir/report.json"
test ! -e "$positive_dir/report.json"

grep -F 'PRODUCTION_PVC_COVERAGE=PASS (1/1)' "$output" >/dev/null
grep -F 'CNPG_BACKUP_CONFIGURATION=PASS (1/1)' "$output" >/dev/null
grep -F 'CNPG_RESTORE_PROOF=UNPROVEN' "$output" >/dev/null
grep -F 'RESTORE_DRILL_SUCCESS=FAIL' "$output" >/dev/null
grep -F 'RESTORE_RESIDUE_COUNT=2' "$output" >/dev/null
grep -F 'ORPHAN_PVC_COUNT=1' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_GAPS=2' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_LEGACY_GAPS=2' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_UNVERIFIED=0' "$output" >/dev/null

# A label-selected Velero schedule must cover only PVCs mounted by matching
# pods. A namespace-wide fallback would incorrectly mark the unselected PVC as
# scheduled and hide the resulting protection gap.
cp -R "$fixture_dir/." "$selector_dir/"
jq '.items += [
  {"metadata":{"namespace":"selector-fixture","name":"durable","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-durable"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"selector-fixture","name":"unselected","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-unselected"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"selector-fixture","name":"or-durable","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-or-durable"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"selector-fixture","name":"or-unselected","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-or-unselected"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"selector-fixture","name":"expr-durable","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-expr-durable"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"selector-fixture","name":"expr-unselected","labels":{}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-selector-expr-unselected"},"status":{"phase":"Bound"}}
]' "$selector_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/pvc.json"
jq '.items += [
  {"metadata":{"name":"pv-selector-durable"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"durable"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-selector-unselected"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"unselected"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-selector-or-durable"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"or-durable"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-selector-or-unselected"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"or-unselected"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-selector-expr-durable"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"expr-durable"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-selector-expr-unselected"},"spec":{"claimRef":{"namespace":"selector-fixture","name":"expr-unselected"}},"status":{"phase":"Bound"}}
]' "$selector_dir/pv.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/pv.json"
jq '.items += [
  {"metadata":{"namespace":"selector-fixture","name":"durable-pod","labels":{"backup.smadja.dev/velero":"true"}},"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"durable"}}]}},
  {"metadata":{"namespace":"selector-fixture","name":"or-durable-pod","labels":{"selector.or":"yes"}},"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"or-durable"}}]}},
  {"metadata":{"namespace":"selector-fixture","name":"expr-durable-pod","labels":{"selector.tier":"durable"}},"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"expr-durable"}}]}}
]' \
  "$selector_dir/pods.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/pods.json"
jq '.items += [
  {"metadata":{"namespace":"velero","name":"daily-selector"},"spec":{"template":{"includedNamespaces":["selector-fixture"],"labelSelector":{"matchLabels":{"backup.smadja.dev/velero":"true"}}}}},
  {"metadata":{"namespace":"velero","name":"daily-selector-or"},"spec":{"template":{"includedNamespaces":["selector-fixture"],"orLabelSelectors":[{"matchLabels":{"selector.or":"yes"}}]}}},
  {"metadata":{"namespace":"velero","name":"daily-selector-expr"},"spec":{"template":{"includedNamespaces":["selector-fixture"],"labelSelector":{"matchExpressions":[{"key":"selector.tier","operator":"In","values":["durable"]}]}}}}
]' \
  "$selector_dir/schedules.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/schedules.json"
jq '.items += [
  {"metadata":{"namespace":"velero","name":"daily-selector-20261105","labels":{"velero.io/schedule-name":"daily-selector"}},"spec":{"includedNamespaces":["selector-fixture"]},"status":{"phase":"Completed"}},
  {"metadata":{"namespace":"velero","name":"daily-selector-or-20261105","labels":{"velero.io/schedule-name":"daily-selector-or"}},"spec":{"includedNamespaces":["selector-fixture"]},"status":{"phase":"Completed"}},
  {"metadata":{"namespace":"velero","name":"daily-selector-expr-20261105","labels":{"velero.io/schedule-name":"daily-selector-expr"}},"spec":{"includedNamespaces":["selector-fixture"]},"status":{"phase":"Completed"}}
]' \
  "$selector_dir/backups.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/backups.json"
jq '.items += [
  {"metadata":{"namespace":"velero","name":"selector-durable-pvb","labels":{"velero.io/backup-name":"daily-selector-20261105","velero.io/pvc-namespace":"selector-fixture","velero.io/pvc-name":"durable"}},"spec":{"pod":{"namespace":"selector-fixture","name":"durable-pod"},"volume":"data"},"status":{"phase":"Completed"}},
  {"metadata":{"namespace":"velero","name":"selector-or-durable-pvb","labels":{"velero.io/backup-name":"daily-selector-or-20261105","velero.io/pvc-namespace":"selector-fixture","velero.io/pvc-name":"or-durable"}},"spec":{"pod":{"namespace":"selector-fixture","name":"or-durable-pod"},"volume":"data"},"status":{"phase":"Completed"}},
  {"metadata":{"namespace":"velero","name":"selector-expr-durable-pvb","labels":{"velero.io/backup-name":"daily-selector-expr-20261105","velero.io/pvc-namespace":"selector-fixture","velero.io/pvc-name":"expr-durable"}},"spec":{"pod":{"namespace":"selector-fixture","name":"expr-durable-pod"},"volume":"data"},"status":{"phase":"Completed"}}
]' \
  "$selector_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$selector_dir/pvbs.json"
selector_report="$selector_dir/report.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$selector_dir" BACKUP_AUDIT_REPORT_FILE="$selector_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
selector_rc=$?
set -e
(( selector_rc != 0 ))
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "durable")][0] | .scheduled == true and .completedBackup == true and .completedPVB == true' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "unselected")][0] | .scheduled == false and .completedBackup == false and .completedPVB == false' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "or-durable")][0] | .scheduled == true and .completedBackup == true and .completedPVB == true' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "or-unselected")][0] | .scheduled == false and .completedBackup == false and .completedPVB == false' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "expr-durable")][0] | .scheduled == true and .completedBackup == true and .completedPVB == true' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "selector-fixture" and .name == "expr-unselected")][0] | .scheduled == false and .completedBackup == false and .completedPVB == false' \
  "$selector_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "invoice-ninja" and .name == "storage")][0] | .scheduled == true and .completedBackup == true' \
  "$selector_report" >/dev/null

# Pod-level FSB exclusions must prevent a PodVolumeBackup for the named
# volume, while an important sibling volume in the same schedule still needs
# an exact completed PVB correlation.
cp -R "$fixture_dir/." "$fsb_dir/"
jq '.items += [
  {"metadata":{"namespace":"fsb-fixture","name":"logs"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-fsb-logs"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"fsb-fixture","name":"important"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-fsb-important"},"status":{"phase":"Bound"}}
]' "$fsb_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/pvc.json"
jq '.items += [
  {"metadata":{"name":"pv-fsb-logs"},"spec":{"claimRef":{"namespace":"fsb-fixture","name":"logs"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-fsb-important"},"spec":{"claimRef":{"namespace":"fsb-fixture","name":"important"}},"status":{"phase":"Bound"}}
]' "$fsb_dir/pv.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/pv.json"
jq '.items += [
  {"metadata":{"namespace":"fsb-fixture","name":"logs-pod","annotations":{"backup.velero.io/backup-volumes-excludes":"logs"}},"spec":{"volumes":[{"name":"logs","persistentVolumeClaim":{"claimName":"logs"}}]}},
  {"metadata":{"namespace":"fsb-fixture","name":"important-pod"},"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"important"}}]}}
]' "$fsb_dir/pods.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/pods.json"
jq '.items += [{"metadata":{"namespace":"velero","name":"daily-fsb"},"spec":{"template":{"includedNamespaces":["fsb-fixture"]}}}]' \
  "$fsb_dir/schedules.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/schedules.json"
jq '.items += [{"metadata":{"namespace":"velero","name":"daily-fsb-20261105","labels":{"velero.io/schedule-name":"daily-fsb"}},"spec":{"includedNamespaces":["fsb-fixture"]},"status":{"phase":"Completed"}}]' \
  "$fsb_dir/backups.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/backups.json"
jq '.items += [{"metadata":{"namespace":"velero","name":"fsb-important-pvb","labels":{"velero.io/backup-name":"daily-fsb-20261105","velero.io/pvc-namespace":"fsb-fixture","velero.io/pvc-name":"important"}},"spec":{"pod":{"namespace":"fsb-fixture","name":"important-pod"},"volume":"data"},"status":{"phase":"Completed"}}]' \
  "$fsb_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$fsb_dir/pvbs.json"
fsb_report="$fsb_dir/report.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$fsb_dir" BACKUP_AUDIT_REPORT_FILE="$fsb_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
fsb_rc=$?
set -e
(( fsb_rc == 0 ))
jq -e '[.pvc[] | select(.namespace == "fsb-fixture" and .name == "logs")] | length == 0' "$fsb_report" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "fsb-fixture" and .name == "important")][0] | .completedPVB == true and .backupMechanism == "velero/kopia"' "$fsb_report" >/dev/null

# Explicit recovery-purpose labels classify isolated recovery fixtures as
# restore residue without guessing from a namespace name or treating them as
# production backup coverage.
cp -R "$fixture_dir/." "$recovery_label_dir/"
jq '.items += [{"metadata":{"namespace":"plt105-recovery-fixture","name":"recovered","labels":{"recovery.smadja.dev/purpose":"plt105-readonly"}},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-recovered"},"status":{"phase":"Bound"}}]' \
  "$recovery_label_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$recovery_label_dir/pvc.json"
jq '.items += [{"metadata":{"name":"pv-recovered"},"spec":{"claimRef":{"namespace":"plt105-recovery-fixture","name":"recovered"}},"status":{"phase":"Bound"}}]' \
  "$recovery_label_dir/pv.json" >"$tmp_json"
mv "$tmp_json" "$recovery_label_dir/pv.json"
recovery_label_report="$recovery_label_dir/report.json"
BACKUP_AUDIT_INPUT_DIR="$recovery_label_dir" BACKUP_AUDIT_REPORT_FILE="$recovery_label_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
grep -F 'PRODUCTION_PVC_COVERAGE=PASS (1/1)' "$output" >/dev/null
jq -e '[.productionPVCs[] | select(.namespace == "plt105-recovery-fixture")] | length == 0' \
  "$recovery_label_report" >/dev/null
jq -e '[.restorePVCs[] | select(.namespace == "plt105-recovery-fixture")][0] | .classification == "synthetic/test" and .drill == true' \
  "$recovery_label_report" >/dev/null

cp -R "$fixture_dir/." "$stale_evidence_dir/"
jq '.items += [
  {"metadata":{"namespace":"dr-protect-20261020-immich","name":"restored-redis-data","uid":"restore-proof-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"restore-proof-pv"},"status":{"phase":"Bound"}}
]' "$stale_evidence_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$stale_evidence_dir/pvc.json"
BACKUP_AUDIT_INPUT_DIR="$stale_evidence_dir" BACKUP_AUDIT_REPORT_FILE="$stale_evidence_dir/report.json" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
jq -e '.productionPVCs | all(.[]; .namespace != "dr-protect-20261020-immich")' \
  "$stale_evidence_dir/report.json" >/dev/null
jq -e '[.restorePVCs[] | select(.namespace == "dr-protect-20261020-immich")][0].classification == "synthetic/test"' \
  "$stale_evidence_dir/report.json" >/dev/null

cp -R "$fixture_dir/." "$longhorn_dir/"
jq '.producedAt = (now | todateiso8601)' "$longhorn_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/restore-evidence.json"
jq '.items=[]' "$longhorn_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/pvbs.json"
jq '.items=[{"metadata":{"name":"pv-invoice-storage"},"status":{"kubernetesStatus":{"namespace":"invoice-ninja","pvcName":"storage"}}}]' \
  "$longhorn_dir/longhorn-volumes.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-volumes.json"
jq '.items[0].metadata.labels={"recurring-job.longhorn.io/immich-redis-offsite":"enabled"}' \
  "$longhorn_dir/longhorn-volumes.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-volumes.json"
jq '.items=[{"metadata":{"name":"immich-redis-offsite"},"spec":{"task":"backup","groups":[]}}]' \
  "$longhorn_dir/longhorn-recurringjobs.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-recurringjobs.json"
jq '.items=[{"metadata":{"name":"backup-invoice-storage"},"status":{"state":"Completed","volumeName":"pv-invoice-storage"}}]' \
  "$longhorn_dir/longhorn-backups.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/longhorn-backups.json"
# Positive synthetic fixture must be fresh at execution time.
# Keep the source fixture and the explicit stale-evidence refusal test unchanged.
jq '.producedAt=(now | todateiso8601) | .items=[
  {"kind":"Velero/Kopia","status":"PASS","accepted":true},
  {"kind":"CNPG/Barman","status":"PASS","accepted":true}
]' "$longhorn_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$longhorn_dir/restore-evidence.json"
longhorn_report="$longhorn_dir/report.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$longhorn_dir" BACKUP_AUDIT_REPORT_FILE="$longhorn_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output"
longhorn_rc=$?
set -e
(( longhorn_rc != 0 ))
jq -e '.productionPVCs[0].backupMechanism == "longhorn-s3-supplemental" and .productionPVCs[0].longhornBackupSupplemental == true and .productionPVCs[0].offsiteBackupVerified == false' \
  "$longhorn_report" >/dev/null
jq -e '.productionPVCs[0].recurringBackupConfigured == true' "$longhorn_report" >/dev/null

cp -R "$fixture_dir/." "$stale_evidence_dir/"
jq '.producedAt="2020-01-01T00:00:00Z"' "$stale_evidence_dir/restore-evidence.json" >"$tmp_json"
mv "$tmp_json" "$stale_evidence_dir/restore-evidence.json"
BACKUP_AUDIT_INPUT_DIR="$stale_evidence_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output"
grep -F 'CNPG_RESTORE_PROOF=UNPROVEN' "$output" >/dev/null
grep -F 'RESTORE_DRILL_SUCCESS=FAIL' "$output" >/dev/null

cp -R "$fixture_dir/." "$policy_dir/"
jq '.items += [
  {"metadata":{"namespace":"immich","name":"redis-data-immich-redis-master-0","uid":"redis-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-redis"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"mastra-sandbox","name":"workspace-sandbox-claim-05473af3","uid":"mastra-active-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-mastra-active"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"mastra-sandbox","name":"workspace-sandbox-claim-0de14859","uid":"mastra-suspended-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-mastra-suspended"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"synthetic","name":"ephemeral-workspace","uid":"ephemeral-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-ephemeral"},"status":{"phase":"Bound"}},
  {"metadata":{"namespace":"synthetic","name":"accepted-loss-cache","uid":"accepted-loss-uid"},"spec":{"storageClassName":"longhorn-fast","volumeName":"pv-accepted-loss"},"status":{"phase":"Bound"}}
]' "$policy_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$policy_dir/pvc.json"
jq '.items += [
  {"metadata":{"name":"pv-redis"},"spec":{"claimRef":{"namespace":"immich","name":"redis-data-immich-redis-master-0","uid":"redis-uid"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-mastra-active"},"spec":{"claimRef":{"namespace":"mastra-sandbox","name":"workspace-sandbox-claim-05473af3","uid":"mastra-active-uid"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-mastra-suspended"},"spec":{"claimRef":{"namespace":"mastra-sandbox","name":"workspace-sandbox-claim-0de14859","uid":"mastra-suspended-uid"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-ephemeral"},"spec":{"claimRef":{"namespace":"synthetic","name":"ephemeral-workspace","uid":"ephemeral-uid"}},"status":{"phase":"Bound"}},
  {"metadata":{"name":"pv-accepted-loss"},"spec":{"claimRef":{"namespace":"synthetic","name":"accepted-loss-cache","uid":"accepted-loss-uid"}},"status":{"phase":"Bound"}}
]' "$policy_dir/pv.json" >"$tmp_json"
mv "$tmp_json" "$policy_dir/pv.json"
policy_report="$policy_dir/report.json"
BACKUP_AUDIT_INPUT_DIR="$policy_dir" BACKUP_AUDIT_REPORT_FILE="$policy_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output" || true
grep -F 'PRODUCTION_RECOVERY_STATUS=FAIL' "$output" >/dev/null
jq -e '.productionRecovery.protected == 1 and .productionRecovery.unknownReview == 2 and .productionRecovery.unprotected == 1 and (.productionPVC.covered == 1) and ([.productionPVCs[] | select(.namespace == "mastra-sandbox") | .policyMatched] | all) and ([.pvc[] | select(.namespace == "synthetic") | .recoveryStatus] | sort == ["EPHEMERAL_VERIFIED", "EXCLUDE_ACCEPTED_LOSS"])' \
  "$policy_report" >/dev/null

cp -R "$policy_dir/." "$stale_policy_dir/"
jq '(.items[] | select(.metadata.name == "workspace-sandbox-claim-05473af3") | .metadata.uid) = "recreated-uid"' \
  "$stale_policy_dir/pvc.json" >"$tmp_json"
mv "$tmp_json" "$stale_policy_dir/pvc.json"
stale_policy_report="$stale_policy_dir/report.json"
BACKUP_AUDIT_INPUT_DIR="$stale_policy_dir" BACKUP_AUDIT_REPORT_FILE="$stale_policy_report" \
  bash "$repo_root/scripts/backup-audit.sh" >"$output" || true
jq -e '[.productionPVCs[] | select(.namespace == "mastra-sandbox" and .name == "workspace-sandbox-claim-05473af3")][0] | .policyMatched == false and .recoveryStatus == "UNPROTECTED"' \
  "$stale_policy_report" >/dev/null

cp -R "$fixture_dir/." "$negative_dir/"
tmp_json="$negative_dir/pvbs.tmp.json"
jq '.items=[]' "$negative_dir/pvbs.json" >"$tmp_json"
mv "$tmp_json" "$negative_dir/pvbs.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$negative_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output" 2>&1
missing_pvb_rc=$?
set -e
(( missing_pvb_rc != 0 ))
grep -F 'PRODUCTION_PVC_COVERAGE=UNKNOWN' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_UNVERIFIED=1' "$output" >/dev/null

cp -R "$fixture_dir/." "$cnpg_negative_dir/"
jq '.items[0].status.phase="Failed"' "$cnpg_negative_dir/cnpg-backups.json" >"$tmp_json"
mv "$tmp_json" "$cnpg_negative_dir/cnpg-backups.json"
set +e
BACKUP_AUDIT_INPUT_DIR="$cnpg_negative_dir" bash "$repo_root/scripts/backup-audit.sh" >"$output" 2>&1
failed_cnpg_rc=$?
set -e
(( failed_cnpg_rc != 0 ))
grep -F 'CNPG_BACKUP_CONFIGURATION=FAIL' "$output" >/dev/null
grep -F 'BACKUP_AUDIT_LEGACY_GAPS=3' "$output" >/dev/null

echo "backup-audit contract: PASS"
