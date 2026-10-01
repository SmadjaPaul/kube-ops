#!/usr/bin/env bash
set -euo pipefail
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
kubectl get pvc -A -o json >"$tmp/pvc.json"
kubectl get schedules.velero.io -n velero -o json >"$tmp/schedules.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/schedules.json"
kubectl get clusters.postgresql.cnpg.io -A -o json >"$tmp/cnpg.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/cnpg.json"
kubectl get scheduledbackups.postgresql.cnpg.io -A -o json >"$tmp/cnpg-backups.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/cnpg-backups.json"
kubectl get objectstores.barmancloud.cnpg.io -A -o json >"$tmp/objectstores.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/objectstores.json"

report="$(jq -n   --slurpfile pvcs "$tmp/pvc.json"   --slurpfile schedules "$tmp/schedules.json"   --slurpfile cnpg "$tmp/cnpg.json"   --slurpfile backups "$tmp/cnpg-backups.json"   --slurpfile stores "$tmp/objectstores.json" '
def schedule_covers($ns): any($schedules[0].items[]?; ((.spec.template.includedNamespaces // []) | index($ns)) != null);
def is_cnpg_pvc: (.metadata.labels["cnpg.io/cluster"] // "") != "";
{
 pvc:[$pvcs[0].items[]|{namespace:.metadata.namespace,name:.metadata.name,storageClass:.spec.storageClassName,cnpg:is_cnpg_pvc,veleroCovered:(if is_cnpg_pvc then null else schedule_covers(.metadata.namespace) end)}],
 cnpg:[$cnpg[0].items[]|. as $c|{namespace:.metadata.namespace,cluster:.metadata.name,walArchiver:any(.spec.plugins[]?;.isWALArchiver==true),scheduledBackup:any($backups[0].items[]?;.metadata.namespace==$c.metadata.namespace and .spec.cluster.name==$c.metadata.name),objectStorePresent:any($stores[0].items[]?;.metadata.namespace==$c.metadata.namespace)}]
} | .uncoveredPVCs=[.pvc[]|select(.cnpg==false and .veleroCovered!=true)] | .uncoveredCNPG=[.cnpg[]|select((.walArchiver and .scheduledBackup and .objectStorePresent)|not)]')"

printf '%s\n' "$report"
missing="$(jq '(.uncoveredPVCs|length)+(.uncoveredCNPG|length)' <<<"$report")"
echo "BACKUP_AUDIT_GAPS=$missing"
(( missing == 0 ))
