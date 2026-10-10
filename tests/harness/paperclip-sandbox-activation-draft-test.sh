#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
draft="$repo_root/k8s/applications/ai/paperclip/poc/kubernetes-execution/activation-draft"

test -f "$draft/README.md"
test -f "$draft/activation-gates.yaml"

# The activation package must remain outside the production resource graph.
! rg -n 'activation-draft' "$repo_root/k8s/applications/ai/paperclip/kustomization.yaml"

rg -q 'selectedOption: A' "$draft/activation-gates.yaml"
rg -q 'agents.x-k8s.io/v1beta1' "$draft/activation-gates.yaml"
rg -q 'v1.0.5' "$draft/activation-gates.yaml"
rg -q 'prerequisiteHead: 15f1c38525715fb8f8070cfa63df1dda3b8bafd4' "$draft/activation-gates.yaml"
rg -q 'requiredImageDigest: human-required-after-paperclip-11-release' "$draft/activation-gates.yaml"
rg -q 'h3HumanApproval: false' "$draft/activation-gates.yaml"
rg -q 'orchestratorApproval: false' "$draft/activation-gates.yaml"
rg -q 'namespaceScope: persistent-per-company' "$draft/activation-gates.yaml"
rg -q 'namespaceDeleteDuringRunCleanup: false' "$draft/activation-gates.yaml"
rg -q 'scope: every-existing-tenant-namespace' "$draft/activation-gates.yaml"
rg -q 'resourcequota' "$draft/activation-gates.yaml"
rg -q 'ciliumnetworkpolicy' "$draft/activation-gates.yaml"
rg -q 'mismatchResult: blocker' "$draft/activation-gates.yaml"
rg -q 'autoRepair: false' "$draft/activation-gates.yaml"
rg -q 'while the tenant namespace remains' "$draft/README.md"
! rg -q 'tenant namespace are cleaned up' "$draft/README.md"

echo 'paperclip sandbox activation draft: PASS (non-live and fail-closed)'
