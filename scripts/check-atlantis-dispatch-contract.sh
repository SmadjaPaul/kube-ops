#!/usr/bin/env bash
set -euo pipefail

test -f scripts/atlantis-dispatch.mjs
test -f tests/harness/atlantis-dispatch.test.mjs
test -f docs/contracts/atlantis-mastra-dispatch-v1.md
test -f docs/contracts/atlantis-runtime-activation-v1.md

# The isolated pilot is intentionally declared in the infrastructure
# ApplicationSet. Runtime apply qualification remains a separate evidence gate.
grep -q '^          - path: k8s/poc/atlantis-plan-only$' \
  k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml
grep -q '^    - namespace: atlantis-system$' \
  k8s/bootstrap/argocd-root/infrastructure-project.yaml
grep -q '^disableApply: false$' k8s/poc/atlantis-plan-only/values.yaml
grep -q '^disableApplyAll: true$' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'ATLANTIS_ALLOW_COMMANDS: version,plan,apply,policy_check' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'atlantis-pilot-bounded-change' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'path: /etc/atlantis/conftest' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'version: 6.16.1' k8s/poc/atlantis-plan-only/kustomization.yaml
grep -q 'v0.48.1@sha256:' k8s/poc/atlantis-plan-only/values.yaml

# The dispatcher is an admission/transport contract, never a replacement for
# Atlantis or OpenTofu and never a place for an API credential.
if grep -En 'ATLANTIS_API_SECRET|X-Atlantis-Token|curl .*api/(plan|apply)|tofu (plan|apply)|terraform (plan|apply)' \
  scripts/atlantis-dispatch.mjs tests/harness/atlantis-dispatch.test.mjs; then
  echo "ERROR: dispatcher contract must not contain credentials or an execution client" >&2
  exit 1
fi

node --test tests/harness/atlantis-dispatch.test.mjs
echo "ATLANTIS_DISPATCH_CONTRACT=PASS"
