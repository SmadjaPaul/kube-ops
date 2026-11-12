#!/usr/bin/env bash
set -euo pipefail

# The former Atlantis GitHub admission hook was retired with the server. ARC
# owns authenticated planning and its native workflow admission instead.
test ! -e k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh
test ! -e k8s/poc/atlantis-plan-only/policies/github-repository-safety.rego
test ! -e k8s/poc/atlantis-plan-only/policies/pilot.rego
! rg -n 'github-atlantis-guard\.sh|atlantis-github-repository-safety|atlantis-server-admission' \
  k8s/poc/atlantis-plan-only k8s/bootstrap/argocd-root k8s/applications/media \
  k8s/infrastructure/monitoring >/dev/null

echo "ATLANTIS_GITHUB_ADMISSION_RETIREMENT=PASS"
