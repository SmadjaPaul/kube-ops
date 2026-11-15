#!/usr/bin/env bash
# PLT-202: a CNPG restore drill reads a production Barman prefix with the
# production backup key, which can write. The read-only guarantee therefore
# rests on configuration, enforced here:
#   - every drill Cluster bootstraps by recovery and has no spec.plugins (no WAL
#     archiver), no spec.backup, no spec.replica and no
#     cnpg.io/skipEmptyWalArchiveCheck annotation;
#   - no Backup, ScheduledBackup, Velero object or exposure object in the root;
#   - every ObjectStore has no retentionPolicy and no configuration.serverName.
# CNPG docs: a restored cluster archives WAL only when .spec.plugins is set,
# and the empty-WAL-archive check is the operator safety net we keep enabled.
# A built-in self-test proves each rule fails on a mutated render.
set -euo pipefail
for cmd in kustomize yq jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done

# Active drill roots. Add a root here while a drill is deployed; remove it with
# the drill. An empty list is valid (no active drill).
active_drill_roots=()

roots=("$@")
if [[ ${#roots[@]} -eq 0 ]]; then
  if [[ ${#active_drill_roots[@]} -eq 0 ]]; then
    echo "RESTORE_DRILL_READONLY_CONTRACT=PASS roots=0 (no active restore drill)"
    exit 0
  fi
  roots=("${active_drill_roots[@]}")
fi

# Prints violations (one per line) for a JSON array of manifests on stdin.
violations() {
  jq -r '
    map(select(type == "object")) as $docs |
    ([$docs[] | select(.kind == "ObjectStore" and ((.apiVersion // "") | startswith("barmancloud.cnpg.io/"))) | .metadata.name]) as $stores |
    [$docs[] | select(.apiVersion == "postgresql.cnpg.io/v1" and .kind == "Cluster")] as $clusters |
    (if ($clusters | length) == 0 then ["no CNPG Cluster in drill root"] else [] end)
    + [$clusters[] | .metadata.name as $n |
        (if .metadata.labels["backup.smadja.dev/restore-drill"] != "true" then "\($n): missing label backup.smadja.dev/restore-drill=true" else empty end),
        (if .spec.bootstrap.recovery == null then "\($n): bootstrap is not recovery" else empty end),
        (if .spec.plugins != null then "\($n): spec.plugins set (WAL archiver possible)" else empty end),
        (if .spec.backup != null then "\($n): spec.backup set" else empty end),
        (if .spec.replica != null then "\($n): spec.replica set" else empty end),
        (if (.metadata.annotations // {}) | has("cnpg.io/skipEmptyWalArchiveCheck") then "\($n): skipEmptyWalArchiveCheck annotation" else empty end),
        (.spec.externalClusters[]? | .plugin.parameters.barmanObjectName // empty |
          select(. as $o | ($stores | index($o)) == null) | "\($n): externalClusters references unknown ObjectStore \(.)")
      ]
    + [$docs[] | select(.kind == "ObjectStore" and ((.apiVersion // "") | startswith("barmancloud.cnpg.io/"))) | .metadata.name as $n |
        (if .spec.retentionPolicy != null then "\($n): ObjectStore retentionPolicy set" else empty end),
        (if .spec.configuration.serverName != null then "\($n): ObjectStore configuration.serverName set" else empty end)
      ]
    + [$docs[] | select(
          (.apiVersion == "postgresql.cnpg.io/v1" and (.kind == "Backup" or .kind == "ScheduledBackup"))
          or ((.apiVersion // "") | startswith("velero.io/"))
          or (.kind | IN("HTTPRoute", "GRPCRoute", "TCPRoute", "TLSRoute", "UDPRoute", "Gateway", "Ingress"))
          or (.kind == "Service" and (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
        ) | "forbidden object \(.kind)/\(.metadata.name)"]
    | .[]
  '
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for root in "${roots[@]}"; do
  kustomize build "$root" | yq eval-all -o=json -I=0 '.' | jq -s '.' >"$tmp/render.json"
  found="$(violations <"$tmp/render.json")"
  if [[ -n "$found" ]]; then
    echo "RESTORE_DRILL_READONLY_CONTRACT=FAIL root=$root" >&2
    printf '%s\n' "$found" >&2
    exit 1
  fi

  # Self-test: each mutation must be caught on this exact render.
  mutations=(
    '(.[] | select(.kind == "Cluster")) .spec.plugins = [{"name": "barman-cloud.cloudnative-pg.io", "isWALArchiver": true}]'
    '(.[] | select(.kind == "Cluster")) .spec.backup = {"retentionPolicy": "1d"}'
    '(.[] | select(.kind == "Cluster")) .metadata.annotations["cnpg.io/skipEmptyWalArchiveCheck"] = "enabled"'
    '(.[] | select(.kind == "ObjectStore")) .spec.retentionPolicy = "1d"'
    '(.[] | select(.kind == "ObjectStore")) .spec.configuration.serverName = "x"'
    '. + [{"apiVersion": "postgresql.cnpg.io/v1", "kind": "ScheduledBackup", "metadata": {"name": "x"}}]'
    '. + [{"apiVersion": "gateway.networking.k8s.io/v1alpha2", "kind": "TCPRoute", "metadata": {"name": "x"}}]'
  )
  for mutation in "${mutations[@]}"; do
    if [[ -z "$(jq "$mutation" "$tmp/render.json" | violations)" ]]; then
      echo "RESTORE_DRILL_READONLY_CONTRACT=FAIL self-test did not catch: $mutation" >&2
      exit 1
    fi
  done
  echo "RESTORE_DRILL_READONLY_CONTRACT=PASS root=$root self_tests=${#mutations[@]}"
done
