#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

tmp=""
report_file=""
cleanup() {
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  [[ -z "$report_file" ]] || rm -f "$report_file"
  if declare -F kube_access_cleanup >/dev/null; then
    kube_access_cleanup
  fi
}
trap cleanup EXIT

if [[ -n "${BACKUP_AUDIT_INPUT_DIR:-}" ]]; then
  input_dir="$BACKUP_AUDIT_INPUT_DIR"
  for file in pvc pv pods schedules backups restores pvbs cnpg cnpg-backups cnpg-scheduled-backups objectstores; do
    [[ -s "$input_dir/$file.json" ]] || {
      echo "ERROR: missing fixture $input_dir/$file.json" >&2
      exit 2
    }
  done
else
  command -v kubectl >/dev/null || { echo "ERROR: kubectl required" >&2; exit 2; }
  source "$(dirname "$0")/lib/kube-preflight.sh"
  require_kube_access
  tmp="$(mktemp -d)"
  input_dir="$tmp"
  kubectl get pvc -A -o json >"$tmp/pvc.json"
  kubectl get pv -o json >"$tmp/pv.json"
  kubectl get pods -A -o json >"$tmp/pods.json"
  kubectl get schedules.velero.io -A -o json >"$tmp/schedules.json"
  kubectl get backups.velero.io -A -o json >"$tmp/backups.json"
  kubectl get restores.velero.io -A -o json >"$tmp/restores.json"
  kubectl get podvolumebackups.velero.io -A -o json >"$tmp/pvbs.json"
  kubectl get clusters.postgresql.cnpg.io -A -o json >"$tmp/cnpg.json"
  kubectl get backups.postgresql.cnpg.io -A -o json >"$tmp/cnpg-backups.json"
  kubectl get scheduledbackups.postgresql.cnpg.io -A -o json >"$tmp/cnpg-scheduled-backups.json"
  kubectl get objectstores.barmancloud.cnpg.io -A -o json >"$tmp/objectstores.json"
fi

report_file="$(mktemp)"
jq -n \
  --slurpfile pvcs "$input_dir/pvc.json" \
  --slurpfile pvs "$input_dir/pv.json" \
  --slurpfile pods "$input_dir/pods.json" \
  --slurpfile schedules "$input_dir/schedules.json" \
  --slurpfile backups "$input_dir/backups.json" \
  --slurpfile restores "$input_dir/restores.json" \
  --slurpfile pvbs "$input_dir/pvbs.json" \
  --slurpfile cnpg "$input_dir/cnpg.json" \
  --slurpfile cnpgbackups "$input_dir/cnpg-backups.json" \
  --slurpfile cnpgscheduled "$input_dir/cnpg-scheduled-backups.json" \
  --slurpfile stores "$input_dir/objectstores.json" '
def items($doc): $doc[0].items // [];
def ns: .metadata.namespace // "default";
def name: .metadata.name;
def is_drill:
  ((.metadata.labels["backup.smadja.dev/restore-drill"] // "") == "true") or
  ((.metadata.labels["qa.smadja.dev/restore"] // "") == "true") or
  ((ns | test("(^|[-])restore([-]|$)|(^|[-])drill([-]|$)")));
def is_rebuildable:
  (.metadata.labels["backup.smadja.dev/strategy"] // "") == "rebuildable";
def is_excluded:
  # An explicit Velero exclusion is an operator-declared EXCLUDE decision. It
  # is not recovery proof and must not be reported as a protected PVC gap.
  (.metadata.annotations["velero.io/exclude-from-backup"] // "") == "true";
def is_cnpg:
  (.metadata.labels["cnpg.io/cluster"] // "") != "";
def is_restore_drill:
  ((.metadata.labels["backup.smadja.dev/restore-drill"] // "") == "true") or
  ((.metadata.labels["qa.smadja.dev/restore"] // "") == "true") or
  ((name | test("restore|drill"; "i")));
def is_cnpg_restore:
  ((.metadata.labels["cnpg.io/cluster"] // "") != "") or
  ((.metadata.labels["backup.smadja.dev/cnpg-cluster"] // "") != "") or
  ((.metadata.annotations["backup.smadja.dev/cnpg-cluster"] // "") != "");
def completed_backups: [items($backups)[] | select((.status.phase // "") == "Completed")];
def completed_pvbs: [items($pvbs)[] | select((.status.phase // "") == "Completed")];
def pvb_backup_completed($pvb):
  any(completed_backups[];
    .metadata.namespace == ($pvb.metadata.namespace // "") and
    .metadata.name == ($pvb.metadata.labels["velero.io/backup-name"] // ""));
def bound_pv_for($pvc):
  any(items($pvs)[];
    .metadata.name == ($pvc.spec.volumeName // "") and
    (.status.phase // "") == "Bound" and
    (.spec.claimRef.namespace // "") == ($pvc | ns) and
    (.spec.claimRef.name // "") == ($pvc | name));
def schedule_for_namespace($namespace):
  any(items($schedules)[]; (.spec.template.includedNamespaces // []) | index($namespace));
def completed_backup_for_namespace($namespace):
  any(completed_backups[];
    ((.spec.includedNamespaces // []) | index($namespace)) != null or
    ((.metadata.labels["velero.io/schedule-name"] // "") as $schedule |
      any(items($schedules)[]; .metadata.name == $schedule and
        ((.spec.template.includedNamespaces // []) | index($namespace)) != null)));
def pvb_for_pvc($pvc):
  any(completed_pvbs[] | select(pvb_backup_completed(.)); . as $pvb |
    ((.metadata.labels["velero.io/pvc-namespace"] // "") == ($pvc | ns) and
     (.metadata.labels["velero.io/pvc-name"] // "") == ($pvc | name)) or
    ((.spec.pvc.namespace // "") == ($pvc | ns) and
     (.spec.pvc.name // "") == ($pvc | name)) or
    (any(items($pods)[]; .metadata.namespace == ($pvc | ns) and
      .metadata.name == ($pvb.spec.pod.name // "") and
      any(.spec.volumes[]?; .name == ($pvb.spec.volume // "") and
        .persistentVolumeClaim.claimName == ($pvc | name)))));
def cnpg_wal:
  any(.spec.plugins[]?; .isWALArchiver == true) or
  (.spec.backup.barmanObjectStore? != null);
def cnpg_store_name($cluster):
  ([ $cluster.spec.plugins[]?.parameters.barmanObjectName? |
     select(. != null and . != "") ] | first) //
  ($cluster.spec.backup.barmanObjectStore.name // "");
def cnpg_backup_for($cluster):
  any(items($cnpgbackups)[];
    (.metadata.namespace == ($cluster | ns)) and
    (.spec.cluster.name == ($cluster | name)) and
    ((.status.phase // "") == "completed" or (.status.phase // "") == "Completed"));
def cnpg_scheduled_backup_for($cluster):
  any(items($cnpgscheduled)[];
    (.metadata.namespace == ($cluster | ns)) and
    (.spec.cluster.name == ($cluster | name)));
def cnpg_scheduled_store_name($cluster):
  ([ items($cnpgscheduled)[] |
     select(.metadata.namespace == ($cluster | ns) and
       .spec.cluster.name == ($cluster | name)) |
     .spec.pluginConfiguration.parameters.barmanObjectName? |
     select(. != null and . != "") ] | first) // "";
def cnpg_store_for($cluster):
  (cnpg_store_name($cluster)) as $cluster_store |
  (cnpg_scheduled_store_name($cluster)) as $scheduled_store |
  any(items($stores)[];
    .metadata.namespace == ($cluster | ns) and
    .metadata.name == $cluster_store and
    $cluster_store != "" and
    ($scheduled_store == "" or $scheduled_store == $cluster_store));
def accepted_restore:
  ((.metadata.annotations["backup.smadja.dev/restore-accepted"] // "") == "true") or
  ((.metadata.labels["backup.smadja.dev/restore-accepted"] // "") == "true") or
  (.status.appAccepted == true);
def restore_statuses:
  [items($restores)[] | {namespace:ns, name:name, phase:(.status.phase // "Unknown"), accepted:accepted_restore, drill:is_restore_drill, cnpg:is_cnpg_restore}];

([items($pvcs)[] | {
  namespace:ns,
  name:name,
  storageClass:(.spec.storageClassName // ""),
  bound:(.status.phase == "Bound"),
  pvBound:(bound_pv_for(.)),
  drill:is_drill,
  cnpg:is_cnpg,
  rebuildable:is_rebuildable,
  excluded:is_excluded,
  orphan:((.metadata.labels["backup.smadja.dev/orphan"] // "") == "true"),
  volume:(.spec.volumeName // ""),
  scheduled:(schedule_for_namespace(ns)),
  completedBackup:(completed_backup_for_namespace(ns)),
  completedPVB:(pvb_for_pvc(.))
}] | map(select((.rebuildable or .excluded) | not))) as $all_pvcs |
($all_pvcs | map(select(.drill))) as $drill_pvcs |
($all_pvcs | map(select((.drill or .cnpg) | not))) as $production_pvcs |
([items($pvs)[] | {name:name, phase:(.status.phase // "Unknown"), claimNamespace:(.spec.claimRef.namespace // ""), claimName:(.spec.claimRef.name // "")}]) as $pv_inventory |
([items($cnpg)[] | . as $cluster | {
  namespace:ns,
  cluster:name,
  walArchiver:cnpg_wal,
  scheduledBackup:cnpg_scheduled_backup_for($cluster),
  completedBackup:cnpg_backup_for($cluster),
  objectStore:cnpg_store_for($cluster),
  objectStoreName:cnpg_store_name($cluster),
  scheduledObjectStoreName:cnpg_scheduled_store_name($cluster)
}]) as $cnpg_inventory |
(restore_statuses) as $restores |
($restores | map(select(.cnpg))) as $cnpg_restores |
($restores | map(select(.drill))) as $drill_restores |
{
  pvc:$all_pvcs,
  productionPVCs:$production_pvcs,
  restorePVCs:$drill_pvcs,
  pv:$pv_inventory,
  cnpg:$cnpg_inventory,
  restores:$restores,
  productionPVC:{
    total:($production_pvcs|length),
    covered:([ $production_pvcs[] | select(.bound and .pvBound and .scheduled and .completedBackup and .completedPVB) ]|length),
    uncovered:([ $production_pvcs[] | select((.bound and .pvBound and .scheduled and .completedBackup)|not) ]),
    unverified:([ $production_pvcs[] | select(.bound and .pvBound and .scheduled and .completedBackup and (.completedPVB|not)) ])
  },
  cnpgConfiguration:{
    total:($cnpg_inventory|length),
    covered:([ $cnpg_inventory[] | select(.walArchiver and .scheduledBackup and .completedBackup and .objectStore and
      .objectStoreName == .scheduledObjectStoreName) ]|length),
    uncovered:([ $cnpg_inventory[] | select((.walArchiver and .scheduledBackup and .completedBackup and .objectStore and
      .objectStoreName == .scheduledObjectStoreName)|not) ])
  },
  cnpgRestoreProof:{
    completed:([ $cnpg_restores[] | select((.phase == "Completed" or .phase == "complete") and .accepted) ]|length),
    unacceptedCompleted:([ $cnpg_restores[] | select((.phase == "Completed" or .phase == "complete") and (.accepted|not)) ]|length)
  },
  restoreDrills:{
    total:($drill_restores|length),
    accepted:([ $drill_restores[] | select((.phase == "Completed" or .phase == "complete") and .accepted) ]|length),
    completedUnaccepted:([ $drill_restores[] | select((.phase == "Completed" or .phase == "complete") and (.accepted|not)) ]|length),
    failed:([ $drill_restores[] | select(.phase == "Failed" or .phase == "failed") ]|length)
  },
  restoreResidueCount:($drill_pvcs|length),
  orphanPVCCount:([ $all_pvcs[] | select(.orphan) ]|length),
  pvCount:($pv_inventory|length)
} |
.productionPVCStatus=(if .productionPVC.total == 0 then "NOT_APPLICABLE" elif (.productionPVC.uncovered|length)>0 then "FAIL" elif (.productionPVC.unverified|length)>0 then "UNKNOWN" else "PASS" end) |
.cnpgBackupConfigurationStatus=(if .cnpgConfiguration.total == 0 then "NOT_APPLICABLE" elif (.cnpgConfiguration.uncovered|length)==0 then "PASS" else "FAIL" end) |
.cnpgRestoreProofStatus=(if .cnpgRestoreProof.completed > 0 then "PASS" elif .cnpgRestoreProof.unacceptedCompleted > 0 then "PARTIAL" else "UNPROVEN" end) |
.restoreDrillStatus=(if .restoreDrills.total == 0 then "NONE" elif .restoreDrills.failed > 0 then "FAIL" elif .restoreDrills.completedUnaccepted > 0 then "PARTIAL" elif .restoreDrills.accepted == .restoreDrills.total then "PASS" else "UNPROVEN" end) |
.auditGaps=((.productionPVC.uncovered|length)+(.productionPVC.unverified|length)+
  (.cnpgConfiguration.uncovered|length)+(.restoreResidueCount)) |
.legacyAuditGaps=((.productionPVC.uncovered|length)+(.cnpgConfiguration.uncovered|length)+(.restoreResidueCount)) |
.productionPVCGapCount=((.productionPVC.uncovered|length)+(.productionPVC.unverified|length)+(.cnpgConfiguration.uncovered|length))
' >"$report_file"

report="$(cat "$report_file")"
if [[ "${BACKUP_AUDIT_VERBOSE:-false}" == "true" ]]; then
  cat "$report_file"
fi
printf 'PRODUCTION_PVC_COVERAGE=%s (%s/%s)\n' \
  "$(jq -r '.productionPVCStatus' <<<"$report")" \
  "$(jq -r '.productionPVC.covered' <<<"$report")" \
  "$(jq -r '.productionPVC.total' <<<"$report")"
printf 'PRODUCTION_PVC_UNVERIFIED=%s\n' "$(jq -r '.productionPVC.unverified|length' <<<"$report")"
printf 'CNPG_BACKUP_CONFIGURATION=%s (%s/%s)\n' \
  "$(jq -r '.cnpgBackupConfigurationStatus' <<<"$report")" \
  "$(jq -r '.cnpgConfiguration.covered' <<<"$report")" \
  "$(jq -r '.cnpgConfiguration.total' <<<"$report")"
printf 'CNPG_RESTORE_PROOF=%s\n' "$(jq -r '.cnpgRestoreProofStatus' <<<"$report")"
printf 'RESTORE_DRILL_SUCCESS=%s\n' "$(jq -r '.restoreDrillStatus' <<<"$report")"
printf 'RESTORE_RESIDUE_COUNT=%s\n' "$(jq -r '.restoreResidueCount' <<<"$report")"
printf 'ORPHAN_PVC_COUNT=%s\n' "$(jq -r '.orphanPVCCount' <<<"$report")"
echo "BACKUP_AUDIT_GAPS=$(jq -r '.auditGaps' <<<"$report")"
echo "BACKUP_AUDIT_LEGACY_GAPS=$(jq -r '.legacyAuditGaps' <<<"$report")"
echo "BACKUP_AUDIT_UNVERIFIED=$(jq -r '.productionPVC.unverified|length' <<<"$report")"

# Restore residue and missing application acceptance remain explicit evidence,
# but are not folded into the production coverage exit gate.
(( "$(jq -r '.productionPVCGapCount' <<<"$report")" == 0 ))
