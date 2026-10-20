#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

tmp=""
report_file=""
scratch="$(mktemp -d)"
collection_status="COMPLETE"
collection_errors_file="$scratch/collection-errors.json"
cleanup() {
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  [[ -z "$report_file" ]] || rm -f "$report_file"
  rm -rf "$scratch"
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
  for file in longhorn-volumes longhorn-backups longhorn-recurringjobs restore-evidence; do
    [[ -s "$input_dir/$file.json" ]] || {
      printf '%s\n' '{"items":[]}' >"$scratch/$file.json"
    }
  done
  [[ -s "$input_dir/recovery-policy.json" ]] || printf '%s\n' '{"policies":[]}' >"$scratch/recovery-policy.json"
else
  command -v kubectl >/dev/null || { echo "ERROR: kubectl required" >&2; exit 2; }
  source "$(dirname "$0")/lib/kube-preflight.sh"
  require_kube_access
  command -v timeout >/dev/null || { echo "ERROR: timeout required for bounded collection" >&2; exit 2; }
  tmp="$(mktemp -d)"
  input_dir="$tmp"
  resources=(
    'pvc|pvc -A'
    'pv|pv'
    'pods|pods -A'
    'schedules|schedules.velero.io -A'
    'backups|backups.velero.io -A'
    'restores|restores.velero.io -A'
    'pvbs|podvolumebackups.velero.io -A'
    'cnpg|clusters.postgresql.cnpg.io -A'
    'cnpg-backups|backups.postgresql.cnpg.io -A'
    'cnpg-scheduled-backups|scheduledbackups.postgresql.cnpg.io -A'
    'objectstores|objectstores.barmancloud.cnpg.io -A'
    'longhorn-volumes|volumes.longhorn.io -A'
    'longhorn-backups|backups.longhorn.io -A'
    'longhorn-recurringjobs|recurringjobs.longhorn.io -A'
  )
  request_timeout="${BACKUP_AUDIT_REQUEST_TIMEOUT_SECONDS:-8}"
  overall_timeout="${BACKUP_AUDIT_TIMEOUT_SECONDS:-30}"
  effective_timeout="$request_timeout"
  (( overall_timeout < effective_timeout )) && effective_timeout="$overall_timeout"
  pids=()
  names=()
  for spec in "${resources[@]}"; do
    IFS='|' read -r name args <<<"$spec"
    read -r -a argv <<<"$args"
    timeout "${effective_timeout}s" kubectl --request-timeout="${effective_timeout}s" get "${argv[@]}" -o json \
      >"$tmp/$name.json" 2>"$scratch/$name.stderr" &
    pids+=("$!")
    names+=("$name")
  done
  : >"$scratch/collection-errors.tsv"
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      collection_status="PARTIAL"
      reason="$(tr '\n' ' ' <"$scratch/${names[$i]}.stderr" | sed 's/[[:space:]]\+/ /g')"
      printf '%s\t%s\n' "${names[$i]}" "${reason:-request failed or timed out}" >>"$scratch/collection-errors.tsv"
    fi
    [[ -s "$tmp/${names[$i]}.json" ]] || {
      collection_status="PARTIAL"
      printf '%s\n' '{"items":[]}' >"$tmp/${names[$i]}.json"
    }
  done
  jq -Rn '[inputs | split("\t") | {resource: .[0], reason: .[1]}]' \
    <"$scratch/collection-errors.tsv" >"$collection_errors_file"
  printf '%s\n' '{"items":[]}' >"$tmp/restore-evidence.json"
  printf '%s\n' '{"policies":[]}' >"$tmp/recovery-policy.json"
fi

evidence_file="${BACKUP_AUDIT_RESTORE_EVIDENCE_FILE:-}"
if [[ -z "$evidence_file" && -z "${BACKUP_AUDIT_INPUT_DIR:-}" && -s "$(dirname "$0")/../docs/operations/dr-restore-evidence-2026-10-20.json" ]]; then
  evidence_file="$(dirname "$0")/../docs/operations/dr-restore-evidence-2026-10-20.json"
elif [[ -z "$evidence_file" && -z "${BACKUP_AUDIT_INPUT_DIR:-}" && -s "$(dirname "$0")/../docs/operations/dr-restore-evidence-2026-10-19.json" ]]; then
  evidence_file="$(dirname "$0")/../docs/operations/dr-restore-evidence-2026-10-19.json"
fi
if [[ -n "$evidence_file" && -s "$evidence_file" ]]; then
  evidence_input="$evidence_file"
elif [[ -n "${BACKUP_AUDIT_INPUT_DIR:-}" && -s "$input_dir/restore-evidence.json" ]]; then
  evidence_input="$input_dir/restore-evidence.json"
else
  evidence_input="$scratch/restore-evidence.json"
fi
policy_file="${BACKUP_AUDIT_RECOVERY_POLICY_FILE:-}"
if [[ -z "$policy_file" && -z "${BACKUP_AUDIT_INPUT_DIR:-}" && -s "$(dirname "$0")/../docs/operations/pvc-recovery-policy-2026-10-20.json" ]]; then
  policy_file="$(dirname "$0")/../docs/operations/pvc-recovery-policy-2026-10-20.json"
fi
if [[ -n "$policy_file" && -s "$policy_file" ]]; then
  policy_input="$policy_file"
elif [[ -n "${BACKUP_AUDIT_INPUT_DIR:-}" && -s "$input_dir/recovery-policy.json" ]]; then
  policy_input="$input_dir/recovery-policy.json"
else
  policy_input="$scratch/recovery-policy.json"
fi
lh_volumes_input="$input_dir/longhorn-volumes.json"
lh_backups_input="$input_dir/longhorn-backups.json"
lh_recurring_input="$input_dir/longhorn-recurringjobs.json"
[[ -s "$lh_volumes_input" ]] || lh_volumes_input="$scratch/longhorn-volumes.json"
[[ -s "$lh_backups_input" ]] || lh_backups_input="$scratch/longhorn-backups.json"
[[ -s "$lh_recurring_input" ]] || lh_recurring_input="$scratch/longhorn-recurringjobs.json"
[[ -s "$collection_errors_file" ]] || printf '%s\n' '[]' >"$collection_errors_file"

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
  --slurpfile stores "$input_dir/objectstores.json" \
  --slurpfile lhvolumes "$lh_volumes_input" \
  --slurpfile lhbackups "$lh_backups_input" \
  --slurpfile lhrecurring "$lh_recurring_input" \
  --slurpfile evidence "$evidence_input" \
  --slurpfile recoveryPolicies "$policy_input" \
  --slurpfile collectionErrors "$collection_errors_file" \
  --arg collectionStatus "$collection_status" \
  --arg observedAt "${BACKUP_AUDIT_OBSERVED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  --arg requireUIDs "$([[ -z "${BACKUP_AUDIT_INPUT_DIR:-}" ]] && echo true || echo false)" '
def items($doc): $doc[0].items // [];
def ns: .metadata.namespace // "default";
def name: .metadata.name;
def is_drill:
  ((.metadata.labels["backup.smadja.dev/restore-drill"] // "") == "true") or
  ((.metadata.labels["qa.smadja.dev/restore"] // "") == "true") or
  ((ns | test("(^|[-])restore([-]|$)|(^|[-])drill([-]|$)|(^|[-])dr-protect([-]|$)")));
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
def completed_lh_backups: [items($lhbackups)[] | select((.status.state // .status.phase // "") == "Completed")];
def pvb_backup_completed($pvb; $completed_backup_keys):
  any($completed_backup_keys[];
    . == ((($pvb.metadata.namespace // "") + "/" +
      ($pvb.metadata.labels["velero.io/backup-name"] // ""))));
def bound_pv_for($pvc; $pv_index):
  ($pv_index[($pvc.spec.volumeName // "")] // {}) as $pv |
  (($pv.metadata.name // "") != "" and
   ($pv.status.phase // "") == "Bound" and
   ($pv.spec.claimRef.namespace // "") == ($pvc | ns) and
   ($pv.spec.claimRef.name // "") == ($pvc | name) and
   ($requireUIDs != "true" or
     (($pv.spec.claimRef.uid // "") != "" and
      ($pv.spec.claimRef.uid // "") == ($pvc.metadata.uid // ""))));
def schedule_for_namespace($namespace):
  any(items($schedules)[]; (.spec.template.includedNamespaces // []) | index($namespace));
def completed_backup_for_namespace($namespace; $completed_backup_list):
  any($completed_backup_list[];
    ((.spec.includedNamespaces // []) | index($namespace)) != null or
    ((.metadata.labels["velero.io/schedule-name"] // "") as $schedule |
      any(items($schedules)[]; .metadata.name == $schedule and
        ((.spec.template.includedNamespaces // []) | index($namespace)) != null)));
def pvb_for_pvc($pvc; $pvb_claim_index):
  ($pvb_claim_index[(($pvc | ns) + "/" + ($pvc | name))] // false);
def lh_volume_for($pvc; $lh_volume_index):
  ($lh_volume_index[($pvc.spec.volumeName // "")] //
   $lh_volume_index[(($pvc | ns) + "/" + ($pvc | name))] // null);
def lh_backup_for($pvc; $lh_volume_index; $lh_backup_index):
  (lh_volume_for($pvc; $lh_volume_index) // {}) as $volume |
  ($lh_backup_index[($volume.metadata.name // "")] // false);
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
def evidence_fresh:
  ($evidence[0].producedAt // "") as $produced |
  ($evidence[0].maxAgeSeconds // 86400) as $max_age |
  ($produced != "" and
    ((try ($produced | fromdateiso8601) catch 0) >= (now - $max_age)));
def evidence_pass:
  if evidence_fresh then
    [items($evidence)[] | select((.status // "") == "PASS" and ((.accepted // false) == true or (.applicationAccepted // false) == true))]
  else [] end;
def evidence_for_pvc($pvc):
  [evidence_pass[] | select(
    (.pvc.namespace // "") == ($pvc | ns) and
    (.pvc.name // "") == ($pvc | name) and
    (.pvc.uid // "") == ($pvc.metadata.uid // ""))] | first // null;
def recovery_policy_for($pvc):
  [($recoveryPolicies[0].policies // [])[] |
    select((.namespace // "") == ($pvc | ns) and
      (.name // "") == ($pvc | name) and
      (.uid // "") == ($pvc.metadata.uid // ""))] | first // {};
def has_recovery_evidence($policy; $kind):
  any(($policy.recoveryEvidence // [])[]; (.kind // "") == $kind);
def recovery_status($policy; $offsite; $classification):
  if $offsite then "PROTECTED"
  elif (($policy.recoveryPolicy // "") == "EPHEMERAL_VERIFIED" and
        has_recovery_evidence($policy; "functional-recovery")) then "EPHEMERAL_VERIFIED"
  elif (($policy.recoveryPolicy // "") == "EXCLUDE_ACCEPTED_LOSS" and
        has_recovery_evidence($policy; "operator-acceptance")) then "EXCLUDE_ACCEPTED_LOSS"
  elif (($policy.recoveryPolicy // "") == "UNKNOWN_REVIEW") then "UNKNOWN_REVIEW"
  elif $classification == "production" then "UNPROTECTED"
  else "UNKNOWN_REVIEW" end;
def recurring_backup_for($lhvolume):
  any(items($lhrecurring)[];
    (.spec.task // "") == "backup" and
    ((($lhvolume.metadata.labels // {})[("recurring-job.longhorn.io/" + (.metadata.name // ""))] // "") == "enabled" or
     any((.spec.groups // [])[]; (($lhvolume.metadata.labels // {})[("recurring-job-group.longhorn.io/" + .)] // "") == "enabled")));

 (items($pvs) | reduce .[] as $pv ({}; .[$pv.metadata.name] = $pv)) as $pv_index |
 (completed_backups) as $completed_backups_list |
 ($completed_backups_list | map((.metadata.namespace // "") + "/" + (.metadata.name // ""))) as $completed_backup_keys |
 (completed_pvbs | map(select(pvb_backup_completed(.; $completed_backup_keys)))) as $valid_pvbs |
 (items($pods) | reduce .[] as $pod ({};
   reduce ($pod.spec.volumes[]? | select(.persistentVolumeClaim.claimName? != null)) as $volume (.;
     .[(($pod.metadata.namespace // "default") + "/" + ($pod.metadata.name // "") + "/" + ($volume.name // ""))] =
       (($pod.metadata.namespace // "default") + "/" + ($volume.persistentVolumeClaim.claimName // ""))))) as $pod_volume_index |
 ($valid_pvbs | reduce .[] as $pvb ({};
   .[((($pvb.metadata.labels["velero.io/pvc-namespace"] // "") + "/" + ($pvb.metadata.labels["velero.io/pvc-name"] // "")))] = true |
   .[((($pvb.spec.pvc.namespace // "") + "/" + ($pvb.spec.pvc.name // "")))] = true |
   ((($pvb.spec.pod.namespace // "default") + "/" + ($pvb.spec.pod.name // "") + "/" + ($pvb.spec.volume // "")) as $pod_key |
     if ($pod_volume_index[$pod_key] // "") != "" then
       .[$pod_volume_index[$pod_key]] = true
     else . end))) as $pvb_claim_index |
 (completed_lh_backups) as $valid_lh_backups |
 ($valid_lh_backups | reduce .[] as $backup ({};
   .[($backup.status.volumeName // $backup.spec.volumeName // $backup.metadata.labels["longhorn.io/volume"] // "")] = true)) as $lh_backup_index |
 (items($lhvolumes) | reduce .[] as $volume ({};
   .[$volume.metadata.name] = $volume |
   if (($volume.status.kubernetesStatus.namespace // "") != "" and
       ($volume.status.kubernetesStatus.pvcName // "") != "") then
     .[(($volume.status.kubernetesStatus.namespace // "") + "/" + ($volume.status.kubernetesStatus.pvcName // ""))] = $volume
   else . end)) as $lh_volume_index |
([items($pvcs)[] | . as $pvc |
  (recovery_policy_for($pvc)) as $policy |
  (lh_volume_for($pvc; $lh_volume_index)) as $lhvolume |
  (lh_backup_for($pvc; $lh_volume_index; $lh_backup_index)) as $lhbackup |
  (evidence_for_pvc($pvc)) as $restore_evidence |
  (pvb_for_pvc($pvc; $pvb_claim_index)) as $pvb |
  {
    namespace:ns,
    name:name,
    uid:(.metadata.uid // ""),
    storageClass:(.spec.storageClassName // ""),
    bound:(.status.phase == "Bound"),
    pvBound:(bound_pv_for($pvc; $pv_index)),
    drill:is_drill,
    cnpg:is_cnpg,
    rebuildable:is_rebuildable,
    excluded:is_excluded,
    orphan:((.metadata.labels["backup.smadja.dev/orphan"] // "") == "true"),
    volume:(.spec.volumeName // ""),
    classification:(if is_excluded then "explicitly-excluded" elif is_drill then "synthetic/test" else "production" end),
    decision:(if is_excluded then "EXPLICITLY_EXCLUDED" elif is_drill then "REVIEW" else "PROTECT" end),
    recoveryPolicy:($policy.recoveryPolicy // (if is_excluded then "UNKNOWN_REVIEW" elif is_drill then "UNKNOWN_REVIEW" else "PROTECT_OFFSITE" end)),
    recoveryEvidence:($policy.recoveryEvidence // []),
    lastVerifiedAt:($policy.lastVerifiedAt // ""),
    policyMatched:(($policy.uid // "") != "" and ($policy.uid == (.metadata.uid // ""))),
    scheduled:(schedule_for_namespace(ns)),
    completedBackup:(completed_backup_for_namespace(ns; $completed_backups_list)),
    completedPVB:($pvb != false),
    longhornVolumePresent:($lhvolume != null),
    longhornVolume:($lhvolume.metadata.name // ""),
    longhornBackupCompleted:($lhbackup),
    restoreVerified:($restore_evidence != null and (($restore_evidence.restoreVerified // true) == true)),
    applicationRecoveryVerified:($restore_evidence != null and (($restore_evidence.applicationRecoveryVerified // false) == true)),
    restoreEvidence:($restore_evidence // null),
    recurringBackupConfigured:recurring_backup_for($lhvolume),
    backupConfigured:(schedule_for_namespace(ns) or ($lhbackup)),
    offsiteBackupVerified:(($pvb != false) or ($lhbackup))
  }
  | .coverageReady=(.bound and .pvBound and .backupConfigured and .offsiteBackupVerified)
  | .backupMechanism=(if .completedPVB then "velero/kopia" elif .longhornBackupCompleted then "longhorn-s3" elif .scheduled then "configured-no-completed-proof" else "none" end)
  | .recoveryStatus=(recovery_status($policy; .offsiteBackupVerified; .classification))
  | .lastVerifiedAt=(if .lastVerifiedAt != "" then .lastVerifiedAt elif .offsiteBackupVerified then $observedAt else "" end)
] | map(select((.rebuildable or .excluded) | not))) as $all_pvcs |
($all_pvcs | map(select(.drill))) as $drill_pvcs |
($all_pvcs | map(select((.drill or .cnpg) | not))) as $production_pvcs |
([items($pvs)[] | {name:name, uid:(.metadata.uid // ""), phase:(.status.phase // "Unknown"), claimNamespace:(.spec.claimRef.namespace // ""), claimName:(.spec.claimRef.name // ""), claimUID:(.spec.claimRef.uid // ""), volumeHandle:(.spec.csi.volumeHandle // "")}]) as $pv_inventory |
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
(evidence_pass) as $evidence_pass |
($production_pvcs | map(.recoveryStatus) | group_by(.) | map({key:.[0],value:length}) | from_entries) as $recovery_counts |
{
  schemaVersion:"backup-audit/v2",
  collectionStatus:$collectionStatus,
  collectionErrors:$collectionErrors[0],
  pvc:$all_pvcs,
  productionPVCs:$production_pvcs,
  restorePVCs:$drill_pvcs,
  pv:$pv_inventory,
  cnpg:$cnpg_inventory,
  restores:$restores,
  restoreEvidence:{total:(items($evidence)|length), accepted:($evidence_pass|length), records:$evidence_pass},
  productionPVC:{
    total:($production_pvcs|length),
    covered:([ $production_pvcs[] | select(.coverageReady) ]|length),
    uncovered:([ $production_pvcs[] | select((.bound and .pvBound and .backupConfigured)|not) ]),
    unverified:([ $production_pvcs[] | select(.bound and .pvBound and .backupConfigured and (.offsiteBackupVerified|not)) ])
  },
  productionRecovery:{
    protected:($recovery_counts.PROTECTED // 0),
    ephemeralVerified:($recovery_counts.EPHEMERAL_VERIFIED // 0),
    excludeAcceptedLoss:($recovery_counts.EXCLUDE_ACCEPTED_LOSS // 0),
    unknownReview:($recovery_counts.UNKNOWN_REVIEW // 0),
    unprotected:($recovery_counts.UNPROTECTED // 0)
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
    evidenceAccepted:([ $evidence_pass[] | select(.kind == "CNPG/Barman") ]|length),
    unacceptedCompleted:([ $cnpg_restores[] | select((.phase == "Completed" or .phase == "complete") and (.accepted|not)) ]|length)
  },
  restoreDrills:{
    total:($drill_restores|length),
    accepted:([ $drill_restores[] | select((.phase == "Completed" or .phase == "complete") and .accepted) ]|length),
    completedUnaccepted:([ $drill_restores[] | select((.phase == "Completed" or .phase == "complete") and (.accepted|not)) ]|length),
    failed:([ $drill_restores[] | select(.phase == "Failed" or .phase == "failed") ]|length),
    evidenceAccepted:([ $evidence_pass[] | select(.kind == "Velero/Kopia") ]|length)
  },
  restoreResidueCount:($drill_pvcs|length),
  orphanPVCCount:([ $all_pvcs[] | select(.orphan) ]|length),
  pvCount:($pv_inventory|length)
} |
.productionPVCStatus=(if $collectionStatus != "COMPLETE" then "PARTIAL" elif .productionPVC.total == 0 then "NOT_APPLICABLE" elif (.productionPVC.uncovered|length)>0 then "FAIL" elif (.productionPVC.unverified|length)>0 then "UNKNOWN" else "PASS" end) |
.productionRecoveryStatus=(if $collectionStatus != "COMPLETE" then "PARTIAL" elif .productionPVC.total == 0 then "NOT_APPLICABLE" elif ((.productionRecovery.unknownReview + .productionRecovery.unprotected) > 0) then "FAIL" else "PASS" end) |
.cnpgBackupConfigurationStatus=(if $collectionStatus != "COMPLETE" then "PARTIAL" elif .cnpgConfiguration.total == 0 then "NOT_APPLICABLE" elif (.cnpgConfiguration.uncovered|length)==0 then "PASS" else "FAIL" end) |
.cnpgRestoreProofStatus=(if .cnpgRestoreProof.completed > 0 or .cnpgRestoreProof.evidenceAccepted > 0 then "PASS" elif .cnpgRestoreProof.unacceptedCompleted > 0 then "PARTIAL" else "UNPROVEN" end) |
.restoreDrillStatus=(if .restoreDrills.evidenceAccepted > 0 then "PASS" elif .restoreDrills.total == 0 then "NONE" elif .restoreDrills.failed > 0 then "FAIL" elif .restoreDrills.completedUnaccepted > 0 then "PARTIAL" elif .restoreDrills.accepted == .restoreDrills.total then "PASS" else "UNPROVEN" end) |
.auditGaps=((.productionPVC.uncovered|length)+(.productionPVC.unverified|length)+
  (.cnpgConfiguration.uncovered|length)+(.restoreResidueCount)) |
.legacyAuditGaps=((.productionPVC.uncovered|length)+(.cnpgConfiguration.uncovered|length)+(.restoreResidueCount)) |
.productionPVCGapCount=((.productionPVC.uncovered|length)+(.productionPVC.unverified|length)+(.cnpgConfiguration.uncovered|length)+(if $collectionStatus == "COMPLETE" then 0 else 1 end))
' >"$report_file"

if [[ -n "${BACKUP_AUDIT_REPORT_FILE:-}" ]]; then
  cp "$report_file" "$BACKUP_AUDIT_REPORT_FILE"
fi
report="$(cat "$report_file")"
if [[ "${BACKUP_AUDIT_VERBOSE:-false}" == "true" ]]; then
  cat "$report_file"
fi
printf 'BACKUP_AUDIT_STATUS=%s\n' "$(jq -r 'if .collectionStatus == "COMPLETE" then "COMPLETE" else "PARTIAL" end' <<<"$report")"
printf 'PRODUCTION_PVC_COVERAGE=%s (%s/%s)\n' \
  "$(jq -r '.productionPVCStatus' <<<"$report")" \
  "$(jq -r '.productionPVC.covered' <<<"$report")" \
  "$(jq -r '.productionPVC.total' <<<"$report")"
printf 'PRODUCTION_PVC_UNVERIFIED=%s\n' "$(jq -r '.productionPVC.unverified|length' <<<"$report")"
printf 'PRODUCTION_RECOVERY_STATUS=%s (PROTECTED=%s EPHEMERAL_VERIFIED=%s EXCLUDE_ACCEPTED_LOSS=%s UNKNOWN_REVIEW=%s UNPROTECTED=%s)\n' \
  "$(jq -r '.productionRecoveryStatus' <<<"$report")" \
  "$(jq -r '.productionRecovery.protected' <<<"$report")" \
  "$(jq -r '.productionRecovery.ephemeralVerified' <<<"$report")" \
  "$(jq -r '.productionRecovery.excludeAcceptedLoss' <<<"$report")" \
  "$(jq -r '.productionRecovery.unknownReview' <<<"$report")" \
  "$(jq -r '.productionRecovery.unprotected' <<<"$report")"
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
