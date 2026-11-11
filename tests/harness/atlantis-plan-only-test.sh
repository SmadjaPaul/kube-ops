#!/usr/bin/env bash
set -euo pipefail

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

kustomize build k8s/poc/atlantis-plan-only >"$rendered"

# The ApplicationSet path is intentionally retained as a recovery-volume
# owner. It must not render an Atlantis workload or any credential-bearing
# object.
grep -q '^kind: Namespace$' "$rendered"
grep -q '^  name: atlantis-system$' "$rendered"
grep -q '^kind: PersistentVolumeClaim$' "$rendered"
grep -q '^  name: atlantis-pilot-data$' "$rendered"
grep -q 'argocd.argoproj.io/sync-options: Delete=false' "$rendered"
grep -q 'atlantis.smadja.dev/retention: recovery-only' "$rendered"
grep -q 'atlantis.smadja.dev/server: retired' "$rendered"
grep -q 'recurring-job.longhorn.io/persistent-offsite-backup: enabled' "$rendered"
grep -q 'storageClassName: longhorn-fast' "$rendered"
grep -q 'storage: 5Gi' "$rendered"

if grep -Eq '^kind: (StatefulSet|Deployment|Service|HTTPRoute|ExternalSecret|Secret|ConfigMap|CiliumNetworkPolicy)$' "$rendered"; then
  echo "retired Atlantis root rendered an active workload or credential object" >&2
  exit 1
fi

for retired in \
  k8s/poc/atlantis-plan-only/values.yaml \
  k8s/poc/atlantis-plan-only/webhook-route.yaml \
  k8s/poc/atlantis-plan-only/network-policy.yaml \
  k8s/poc/atlantis-plan-only/github-app-external-secret.yaml \
  k8s/poc/atlantis-plan-only/github-iac-external-secret.yaml \
  k8s/poc/atlantis-plan-only/pilot-backend-external-secret.yaml \
  k8s/poc/atlantis-plan-only/aiostreams-provider-external-secret.yaml \
  k8s/poc/atlantis-plan-only/polyfin-backend-external-secret.yaml \
  k8s/poc/atlantis-plan-only/polyfin-admin-external-secret.yaml \
  k8s/poc/atlantis-plan-only/statefulset-patch.yaml \
  k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh; do
  test ! -e "$retired"
done

if rg -n 'atlantis-servicemonitor|atlantis-observability|atlantis-pilot' \
  k8s/infrastructure/monitoring/prometheus-stack/kustomization.yaml \
  k8s/applications/media/aiostreams/networkpolicy.yaml \
  k8s/applications/media/polyfin/networkpolicy.yaml; then
  echo "active desired state still references the retired Atlantis server" >&2
  exit 1
fi

echo "ATLANTIS_PLAN_ONLY_RETIREMENT=PASS"
