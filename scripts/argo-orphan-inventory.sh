#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/argo-orphan-inventory.sh [--output PATH] [--compare BASELINE]

Collect a read-only Argo orphan inventory. Only object metadata is emitted;
Secret data is never included.
EOF
}

output=-
compare=
while (($# > 0)); do
  case "$1" in
    --output) (($# >= 2)) || { usage >&2; exit 2; }; output=$2; shift 2 ;;
    --compare) (($# >= 2)) || { usage >&2; exit 2; }; compare=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command in argocd date jq kubectl; do
  command -v "$command" >/dev/null || { echo "ERROR: $command required" >&2; exit 2; }
done

source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access >/dev/null

tmp="$(mktemp -d "${TMPDIR:-/tmp}/argo-orphan-inventory.XXXXXX")"
trap 'rm -rf -- "$tmp"; kube_access_cleanup' EXIT
kubectl config set-context --current --namespace=argocd >/dev/null
kubectl -n argocd get applications.argoproj.io -o json >"$tmp/applications.json"
kubectl get httproutes.gateway.networking.k8s.io -A -o json >"$tmp/routes.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/routes.json"
mkdir -p "$tmp/cache"

collect_orphans() {
  local application=$1 project=$2
  argocd app resources "$application" --core --orphaned --output tree=detailed 2>/dev/null |
    awk -v app="$application" -v project="$project" '
      NR == 1 {
        kind_start=index($0,"KIND")
        namespace_start=index($0,"NAMESPACE")
        name_tail=substr($0,namespace_start+length("NAMESPACE"))
        name_start=namespace_start+length("NAMESPACE")+match(name_tail,/NAME[[:space:]]+/)-1
        orphaned_start=index($0,"ORPHANED")
        next
      }
      NR > 1 {
        group=substr($0,1,kind_start-1); kind=substr($0,kind_start,namespace_start-kind_start)
        namespace=substr($0,namespace_start,name_start-namespace_start)
        name=substr($0,name_start,orphaned_start-name_start)
        orphaned=substr($0,orphaned_start,10)
        gsub(/^ +| +$/,"",group); gsub(/^ +| +$/,"",kind)
        gsub(/^ +| +$/,"",namespace); gsub(/^ +| +$/,"",name)
        gsub(/^ +| +$/,"",orphaned)
        if (group == "") group = "-"
        if (name != "" && orphaned == "Yes")
          print group "\t" kind "\t" namespace "\t" name "\t" app "\t" project
      }'
}

collect_orphans apps-catalog applications >"$tmp/apps.tsv"
collect_orphans infra-controllers infrastructure >"$tmp/infra.tsv"
sort -u -k1,4 "$tmp/apps.tsv" "$tmp/infra.tsv" >"$tmp/orphans.tsv"

warning_json="$(jq -c '
  [.items[] |
   ([.status.conditions[]? | select(.type=="OrphanedResourceWarning") | .message] | first) as $message |
   select($message != null) |
   {application:.metadata.name, project:.spec.project, message:$message,
    count:(($message|capture("(?<count>[0-9]+)").count)|tonumber)}]
' "$tmp/applications.json")"
warning_count="$(jq 'length' <<<"$warning_json")"
now_epoch="$(date -u +%s)"

record_object() {
  local group=$1 kind=$2 namespace=$3 name=$4 application=$5 project=$6
  local resource="$kind" object cache
  [[ -n "$group" ]] && resource="$kind.$group"
  cache="$tmp/cache/${group:-core}--$kind.json"
  if [[ ! -f "$cache" ]]; then
    if ! kubectl get "$resource" -A -o json 2>/dev/null |
      jq '{items:[.items[] | {apiVersion,kind,metadata}]}' >"$cache"; then
      : >"$cache"
    fi
  fi
  object="$(jq -c --arg namespace "$namespace" --arg name "$name" '
    .items[]? | select(.metadata.name == $name and ((.metadata.namespace // "") == $namespace))
  ' "$cache")"
  if [[ -z "$object" ]]; then
    jq -nc --arg group "$group" --arg kind "$kind" --arg namespace "$namespace" --arg name "$name" \
      --arg app "$application" --arg project "$project" '{identityKey:(($group+"/"+$kind+"/"+$namespace+"/"+$name)),group:$group,kind:$kind,namespace:$namespace,name:$name,uid:null,creationTimestamp:null,ageDays:null,ownerReferences:[],finalizers:[],managedFields:[],argoTrackingId:null,argoInstance:null,labels:{},sourceApplications:[$app],sourceProjects:[$project],classification:"UNKNOWN",classificationReason:"object disappeared or lookup failed during capture; rerun before acting",hasActiveRoute:false,lookupStatus:"not-found-during-capture"}'
    return 0
  fi
  jq -c --arg group "$group" --arg app "$application" --arg project "$project" \
    --argjson now "$now_epoch" --slurpfile routes "$tmp/routes.json" '
    def restore_drill:
      ((.metadata.namespace//"")|test("(^|-)restore-drill(-|$)")) or
      ((.metadata.name//"")|test("restore-drill|restore-proof"));
    def durable($object):
      ([ "Secret","PersistentVolumeClaim","PersistentVolume","StatefulSet",
         "Backup","Restore","BackupRepository","PodVolumeBackup","PodVolumeRestore",
         "Cluster","ScheduledBackup","ObjectStore","ExternalSecret","Volume",
         "VolumeAttachment" ] | index($object.kind) != null) or
      (.apiVersion|test("^(velero.io|longhorn.io|postgresql.cnpg.io|barmancloud.cnpg.io)/"));
    def active_route($object):
      (($routes[0].items//[]) | any(.[];
        ((.metadata.namespace//"") + "/" + .metadata.name) ==
        (($object.metadata.namespace//"") + "/" + $object.metadata.name)));
    . as $object |
    (if restore_drill then ["RETAINED","restore/backup drill state; human closure required"]
     elif durable($object) then ["RETAINED","durable or operator state; explicit data-owner approval required"]
     elif (($object.metadata.ownerReferences//[])|length)>0 then ["OPERATOR_MANAGED","controller ownerReferences present"]
     elif (($object.metadata.namespace//"")|IN("kube-system","kube-public","argocd")) and
          (($object.kind//"")|IN("ConfigMap","ServiceAccount","Role","RoleBinding","NetworkPolicy"))
          then ["ACTIVE","control-plane object without ownerReferences"]
     elif ((($now-($object.metadata.creationTimestamp|fromdateiso8601))/86400)>=30) and
          (($object.metadata.finalizers//[])|length)==0 and (active_route($object)|not)
          then ["STALE","30d+, no owner/finalizer, and no matching active HTTPRoute"]
     else ["UNKNOWN","no safe lifecycle proof in the read-only inventory"] end) as $class |
    {identityKey:($object.metadata.uid//($group+"/"+$object.kind+"/"+($object.metadata.namespace//"")+"/"+$object.metadata.name)),
     group:$group, apiVersion:$object.apiVersion, kind:$object.kind,
     namespace:($object.metadata.namespace//""), name:$object.metadata.name,
     uid:($object.metadata.uid//null), creationTimestamp:($object.metadata.creationTimestamp//null),
     ageDays:(if $object.metadata.creationTimestamp then (($now-($object.metadata.creationTimestamp|fromdateiso8601))/86400|floor) else null end),
     ownerReferences:($object.metadata.ownerReferences//[]), finalizers:($object.metadata.finalizers//[]),
     managedFields:($object.metadata.managedFields//[]),
     argoTrackingId:($object.metadata.annotations["argocd.argoproj.io/tracking-id"]//null),
     argoInstance:($object.metadata.annotations["argocd.argoproj.io/instance"]//null),
     labels:($object.metadata.labels//{}), sourceApplications:[$app], sourceProjects:[$project],
     classification:$class[0], classificationReason:$class[1], hasActiveRoute:active_route($object), lookupStatus:"found"}
  ' <<<"$object"
}

: >"$tmp/items.ndjson"
while IFS=$'\t' read -r group kind namespace name application project; do
  [[ -n "$name" ]] || continue
  [[ "$group" == "-" ]] && group=
  record_object "$group" "$kind" "$namespace" "$name" "$application" "$project" >>"$tmp/items.ndjson"
done <"$tmp/orphans.tsv"

jq -s --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson warnings "$warning_json" --argjson warningCount "$warning_count" \
  --argjson now "$now_epoch" '
  def counts($field):
    ([.[]|.[$field]]|sort|group_by(.)|map({key:.[0],value:length})|from_entries);
  def age:
    ([.[]|.ageDays]|map(if .==null then "unknown" elif .<1 then "0-1d"
      elif .<7 then "1-7d" elif .<30 then "7-30d" else "30d+" end)
      |sort|group_by(.)|map({key:.[0],value:length})|from_entries);
  . as $items |
  {schemaVersion:"kube-ops/argo-orphan-inventory/v1", generatedAt:$generatedAt,
   observationEpoch:$now,
   source:{applications:["apps-catalog","infra-controllers"],projectWarnings:$warnings,
           projectWarningApplicationCount:$warningCount,secretValuesIncluded:false,
           mutationPerformed:false},
   summary:{uniqueObjects:($items|length),unresolvedObjects:([.[]|select(.lookupStatus!="found")]|length),classification:counts("classification"),
            family:([.[]|((.group//"")+"/"+.kind)]|sort|group_by(.)|map({key:.[0],value:length})|from_entries),
            namespace:counts("namespace"),age:age},
   items:($items|sort_by([.group,.kind,.namespace,.name,.uid]))}
' "$tmp/items.ndjson" >"$tmp/report.json"

if [[ -n "$compare" ]]; then
  jq -e '.items and .schemaVersion' "$compare" >/dev/null
  jq --slurpfile baseline "$compare" '
    . as $current | ($baseline[0]) as $base |
    ([ $current.items[].identityKey ]|unique) as $currentKeys |
    ([ $base.items[].identityKey ]|unique) as $baseKeys |
    .comparison={
      baseline:$base.generatedAt,
      newObjectCount:([$current.items[] as $item|select(($baseKeys|index($item.identityKey))|not)]|length),
      disappearedObjectCount:([$base.items[] as $item|select(($currentKeys|index($item.identityKey))|not)]|length),
      newObjects:[$current.items[] as $item|select(($baseKeys|index($item.identityKey))|not)|$item],
      disappearedObjects:[$base.items[] as $item|select(($currentKeys|index($item.identityKey))|not)|$item|
        .+{disappearanceReason:"not observed; Kubernetes audit/events required to distinguish GC, GitOps prune, TTL expiry, or manual deletion"}]
    }
  ' "$tmp/report.json" >"$tmp/compared.json"
  mv "$tmp/compared.json" "$tmp/report.json"
fi

if [[ "$output" == "-" ]]; then
  cat "$tmp/report.json"
else
  cp "$tmp/report.json" "$output"
  printf 'ARGO_ORPHAN_INVENTORY=%s\n' "$output"
fi
