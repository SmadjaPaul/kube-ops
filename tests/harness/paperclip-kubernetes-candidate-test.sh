#!/usr/bin/env bash
set -euo pipefail

candidate="k8s/applications/ai/paperclip/poc/kubernetes-execution/instance-candidate.yaml"
lock="k8s/applications/ai/paperclip/poc/kubernetes-execution/version-lock.yaml"
production="k8s/applications/ai/paperclip/kustomization.yaml"

test -f "$candidate"
test -f "$lock"
grep -F 'version: "0.1.0"' "$candidate" >/dev/null
grep -F 'npmVersion: "0.1.0"' "$lock" >/dev/null
grep -F 'npmDistIntegrity: NOT_OBSERVED' "$lock" >/dev/null
! grep -F '2026.1005.0' "$lock" >/dev/null
grep -F 'backend: sandbox-cr' "$candidate" >/dev/null
grep -F 'egressPolicy: allowlist' "$candidate" >/dev/null
grep -F 'egressAllowFQDNs:' "$candidate" >/dev/null
grep -F 'perTenantQuota:' "$candidate" >/dev/null
grep -F 'perTenantLimitRange:' "$candidate" >/dev/null
! grep -F 'egressAllowFqdns:' "$candidate" >/dev/null
! grep -E '^        (inCluster|adapterType|podActivityDeadlineSec|jobTtlSecondsAfterFinished):' "$candidate" >/dev/null
! grep -F 'poc/kubernetes-execution' "$production" >/dev/null
! grep -F 'instance-candidate.yaml' "$production" >/dev/null

kustomize build k8s/applications/ai/paperclip/poc/kubernetes-execution >/dev/null

printf '%s\n' 'PAPERCLIP_KUBERNETES_CANDIDATE_CONTRACT_TEST=PASS'
