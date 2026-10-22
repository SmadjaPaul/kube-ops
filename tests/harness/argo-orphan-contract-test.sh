#!/usr/bin/env bash
set -euo pipefail

projects=(
  k8s/bootstrap/argocd-root/applications-project.yaml
  k8s/bootstrap/argocd-root/infrastructure-project.yaml
)

for project in "${projects[@]}"; do
  [[ "$(yq -r '[.spec.destinations[] | select(.namespace | test("[*]"))] | length' "$project")" == 0 ]] || {
    echo "ERROR: wildcard AppProject destination remains in $project" >&2
    exit 1
  }
  [[ "$(yq -r '[.spec.destinations[] | select(.server != "https://kubernetes.default.svc")] | length' "$project")" == 0 ]] || {
    echo "ERROR: AppProject destination is missing the canonical server in $project" >&2
    exit 1
  }
done

if yq -e '.spec.destinations[] | select(.namespace == "renovate")' k8s/bootstrap/argocd-root/applications-project.yaml >/dev/null; then
  echo "ERROR: retired Renovate namespace remains in the applications AppProject" >&2
  exit 1
fi

# Never hide a workload kind globally. The Velero maintenance Job exception is
# name-scoped and is allowed because Kubernetes/Velero creates that exact family.
if yq -r '.spec.orphanedResources.ignore[]? | [.group // "", .kind, .name // ""] | @tsv' "${projects[@]}" 2>/dev/null |
  awk -F '\t' '$2 ~ /^(Pod|Deployment|StatefulSet|DaemonSet)$/ {print; bad=1} $2 == "Job" && $3 != "*-kopia-maintain-job-*" {print; bad=1} END {exit bad}'; then
  :
else
  echo "ERROR: orphan exceptions contain an unscoped workload kind" >&2
  exit 1
fi

cronjobs=(
  k8s/applications/media/recyclarr/cronjob.yaml
  k8s/applications/business/invoice-ninja/backup-logical.yaml
)
# The list covers existing targeted CronJob retention contracts only.
for cronjob in "${cronjobs[@]}"; do
  [[ -f "$cronjob" ]] || {
    echo "ERROR: tracked CronJob retention contract points to missing source: $cronjob" >&2
    exit 1
  }
  yq -e '.kind == "CronJob" and (.spec.successfulJobsHistoryLimit != null) and (.spec.failedJobsHistoryLimit != null) and (.spec.jobTemplate.spec.ttlSecondsAfterFinished == 86400)' "$cronjob" >/dev/null || {
    echo "ERROR: incomplete CronJob retention contract: $cronjob" >&2
    exit 1
  }
done

bash -n scripts/argo-orphan-inventory.sh
echo "ARGO_ORPHAN_STATIC_CONTRACT=PASS"
