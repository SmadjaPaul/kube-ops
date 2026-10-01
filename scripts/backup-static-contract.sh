#!/usr/bin/env bash
set -euo pipefail
for cmd in kustomize yq jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
rendered="$tmp/rendered.yaml"
: >"$rendered"

roots=(
  k8s/applications/ai
  k8s/applications/media
  k8s/applications/automation
  k8s/applications/web
  k8s/applications/tools
  k8s/applications/business
  k8s/applications/catalog
  k8s/applications/games
  k8s/infrastructure/controllers
)
for root in "${roots[@]}"; do
  kustomize build --enable-helm "$root" >>"$rendered"
  printf '\n---\n' >>"$rendered"
done

yq eval-all -o=json -I=0 '.' "$rendered" | jq -s '
  map(select(type=="object")) as $docs |
  [$docs[] |
    select(.kind=="PersistentVolumeClaim") |
    {
      namespace:(.metadata.namespace//"default"),
      name:.metadata.name,
      rebuildable:(.metadata.labels["backup.smadja.dev/strategy"]=="rebuildable")
    }
  ] as $pvcs |
  [$docs[] |
    select(.kind=="StatefulSet" and ((.spec.volumeClaimTemplates//[])|length>0)) |
    {
      namespace:(.metadata.namespace//"default"),
      name:.metadata.name,
      rebuildable:(
        ([.spec.volumeClaimTemplates[]? | .metadata.labels["backup.smadja.dev/strategy"]=="rebuildable"] | length) > 0
        and
        ([.spec.volumeClaimTemplates[]? | select(.metadata.labels["backup.smadja.dev/strategy"]!="rebuildable")] | length) == 0
      )
    }
  ] as $stateful |
  ([$docs[] |
    select(.apiVersion=="velero.io/v1" and .kind=="Schedule") |
    .spec.template.includedNamespaces[]?
  ] | unique) as $veleroNamespaces |
  [$docs[] |
    select(.apiVersion=="postgresql.cnpg.io/v1" and .kind=="Cluster") |
    {
      namespace:(.metadata.namespace//"default"),
      name:.metadata.name,
      wal:any(.spec.plugins[]?; .isWALArchiver==true)
    }
  ] as $clusters |
  [$docs[] |
    select(.apiVersion=="postgresql.cnpg.io/v1" and .kind=="ScheduledBackup") |
    {namespace:(.metadata.namespace//"default"),cluster:.spec.cluster.name}
  ] as $backups |
  [$docs[] |
    select(.kind=="ObjectStore" and (.apiVersion|startswith("barmancloud.cnpg.io/"))) |
    {namespace:(.metadata.namespace//"default"),name:.metadata.name}
  ] as $stores |
  ((([$pvcs[]|select(.rebuildable!=true)]) + ([$stateful[]|select(.rebuildable!=true)])) | map(.namespace) | unique) as $protectedNamespaces |
  {
    protectedNamespaces:$protectedNamespaces,
    rebuildablePVCs:[$pvcs[]|select(.rebuildable==true)],
    veleroNamespaces:$veleroNamespaces,
    cnpg:$clusters,
    missingVelero:[
      $protectedNamespaces[] as $n |
      select(($veleroNamespaces|index($n))==null) |
      $n
    ],
    missingCNPG:[
      $clusters[] as $c |
      select(
        ($c.wal|not) or
        (any($backups[]?; .namespace==$c.namespace and .cluster==$c.name)|not) or
        (any($stores[]?; .namespace==$c.namespace)|not)
      ) |
      $c
    ]
  } |
  .gapCount=((.missingVelero|length)+(.missingCNPG|length))
' >"$tmp/report.json"

cat "$tmp/report.json"
gaps="$(jq -r '.gapCount' "$tmp/report.json")"
echo "BACKUP_STATIC_GAPS=$gaps"
(( gaps == 0 ))
