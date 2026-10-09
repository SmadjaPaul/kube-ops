#!/usr/bin/env bash
set -euo pipefail
for cmd in kubectl jq; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; kube_access_cleanup' EXIT

kubectl get applications.argoproj.io -n argocd -o json >"$tmp/apps.json"
kubectl get gateways.gateway.networking.k8s.io -A -o json >"$tmp/gateways.json"
kubectl get httproutes.gateway.networking.k8s.io -A -o json >"$tmp/routes.json"
kubectl get pods -A -o json >"$tmp/pods.json"
kubectl get pvc -A -o json >"$tmp/pvcs.json"
kubectl get externalsecrets.external-secrets.io -A -o json >"$tmp/eso.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/eso.json"
kubectl get clusters.postgresql.cnpg.io -A -o json >"$tmp/cnpg.json" 2>/dev/null || printf '{"items":[]}' >"$tmp/cnpg.json"

jq -n   --slurpfile apps "$tmp/apps.json"   --slurpfile gateways "$tmp/gateways.json"   --slurpfile routes "$tmp/routes.json"   --slurpfile pods "$tmp/pods.json"   --slurpfile pvcs "$tmp/pvcs.json"   --slurpfile eso "$tmp/eso.json"   --slurpfile cnpg "$tmp/cnpg.json" '
{
  argo: {
    total: ($apps[0].items|length),
    synced: ([$apps[0].items[]|select(.status.sync.status=="Synced")]|length),
    outOfSync: ([$apps[0].items[]|select(.status.sync.status=="OutOfSync")]|length),
    healthy: ([$apps[0].items[]|select(.status.health.status=="Healthy")]|length),
    degraded: ([$apps[0].items[]|select(.status.health.status=="Degraded")]|length),
    missing: ([$apps[0].items[]|select(.status.health.status=="Missing")]|length),
    applications: [$apps[0].items[] | {
      name:.metadata.name,
      sync:(.status.sync.status // null),
      health:(.status.health.status // null),
      targetRevision:(.spec.source.targetRevision // null),
      operationRevision:(.status.operationState.operation.sync.revision // null),
      operationPhase:(.status.operationState.phase // null),
      operationMessage:(.status.operationState.message // null)
    }]
  },
  gateways: {
    total: ($gateways[0].items|length),
    programmed: ([$gateways[0].items[]|select(any(.status.conditions[]?; .type=="Programmed" and .status=="True"))]|length)
  },
  routes: {
    total: ($routes[0].items|length),
    accepted: ([$routes[0].items[]|select(any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="True"))]|length),
    rejected: ([$routes[0].items[]|select(any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="False"))]|length)
  },
  workloads: {
    pods: ($pods[0].items|length),
    notReady: ([$pods[0].items[] | select(
      .status.phase == "Pending" or
      (.status.phase == "Running" and (
        ((.status.containerStatuses // []) | length) == 0 or
        any(.status.containerStatuses[]?; .ready != true)
      ))
    )] | length),
    pending: ([$pods[0].items[] | select(.status.phase == "Pending")]|length),
    failed: ([$pods[0].items[] | select(.status.phase == "Failed")]|length),
    succeeded: ([$pods[0].items[] | select(.status.phase == "Succeeded")]|length)
  },
  storage: {
    pvcs: ($pvcs[0].items|length),
    pending: ([$pvcs[0].items[]|select(.status.phase!="Bound")]|length)
  },
  externalSecrets: {
    total: ($eso[0].items|length),
    notReady: ([$eso[0].items[]|select((any(.status.conditions[]?; .type=="Ready" and .status=="True"))|not)]|length)
  },
  cnpg: {
    total: ($cnpg[0].items|length),
    notReady: ([$cnpg[0].items[]|select((any(.status.conditions[]?; .type=="Ready" and .status=="True"))|not)]|length)
  }
}'
