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
grep -q '^disableApply: false k8s/poc/atlantis-plan-only/values.yaml
grep -q '^disableApplyAll: true$' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'ATLANTIS_ALLOW_COMMANDS: version,plan,apply,policy_check' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'atlantis-pilot-bounded-change' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'path: /etc/atlantis/conftest' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'version: 6.16.1' k8s/poc/atlantis-plan-only/kustomization.yaml
grep -q 'v0.48.1@sha256:' k8s/poc/atlantis-plan-only/values.yaml

# ARC cutover: the server still serves other roots; only the disposable pilot
# must fail before any apply-side environment, credential or OpenTofu step.
python3 - <<'PY'
from pathlib import Path

values = Path("k8s/poc/atlantis-plan-only/values.yaml").read_text()
workflow = values.split("    atlantis-plan-only:", 1)[1]
apply_steps = workflow.split("      apply:\n        steps:\n", 1)[1].split("      import:", 1)[0]
guard = apply_steps.split("          - env:", 1)[0]
assert guard.lstrip().startswith("# ARC owns"), "pilot guard must be first apply step"
assert 'case "$PROJECT_NAME" in' in guard
assert "atlantis-pilot)" in guard
assert 'echo "Atlantis pilot apply denied: ARC is the intended state writer"' in guard
assert "exit 1" in guard
assert "github|aiostreams|polyfin)" in guard
assert "          - run: |" in guard
PY

# The dispatcher is an admission/transport contract, never a replacement for
# Atlantis or OpenTofu and never a place for an API credential.
if grep -En 'ATLANTIS_API_SECRET|X-Atlantis-Token|curl .*api/(plan|apply)|tofu (plan|apply)|terraform (plan|apply)' \
  scripts/atlantis-dispatch.mjs tests/harness/atlantis-dispatch.test.mjs; then
  echo "ERROR: dispatcher contract must not contain credentials or an execution client" >&2
  exit 1
fi

node --test tests/harness/atlantis-dispatch.test.mjs
echo "ATLANTIS_DISPATCH_CONTRACT=PASS"
 k8s/poc/atlantis-plan-only/values.yaml
grep -q '^disableApplyAll: true$' k8s/poc/atlantis-plan-only/values.yaml
grep -q 'ATLANTIS_ALLOW_COMMANDS: version,plan,policy_check' k8s/poc/atlantis-plan-only/values.yaml
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
