#!/usr/bin/env -S just --justfile
set positional-arguments
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    @just --list

[doc('Show concise repository authority and runtime boundary')]
context:
    @echo "Repo: kube-ops (Kubernetes desired state)"
    @echo "External substrate: SmadjaPaul/homelab-infra"
    @echo "Path: Git -> Argo CD -> Kubernetes -> Gateway API"
    @echo "Private app DNS: HTTPRoute -> ExternalDNS -> UniFi"
    @echo "Runtime kube access: auto-bootstrap from Doppler infrastructure/prd; never ask for a manual KUBECONFIG"

[doc('Print compact active desired-state roots and routes')]
inventory:
    bash scripts/inventory.sh

[doc('Run deterministic clusterless V1 + backup validation')]
check:
    npm run check
    bash tests/harness/kube-preflight-test.sh
    bash tests/harness/affected-tests-test.sh
    bash tests/harness/argo-orphan-contract-test.sh
    bash tests/harness/trilium-probe-test.sh
    bash tests/harness/invoice-backup-test.sh
    bash tests/harness/runtime-inventory-test.sh

[doc('Run validators only for Git-diff affected Kustomize components')]
check-affected:
    bash -n scripts/check-agent-harness-contract.sh scripts/check-v1-active-contract.sh scripts/backup-static-contract.sh
    bash tests/harness/argo-orphan-contract-test.sh
    bash tests/harness/invoice-restore-isolation-test.sh
    npm run check:agent-harness
    bash scripts/affected-tests.sh

[doc('Validate canonical operator Kubernetes access; auto-bootstrap from Doppler, never from ~/.kube')]
kube-access-check:
    bash -c 'source scripts/lib/kube-preflight.sh; require_kube_access'

[doc('Read-only Argo/Gateway/workload runtime inventory')]
runtime-inventory:
    bash scripts/runtime-inventory.sh

[doc('Probe every discovered internal HTTPRoute')]
runtime-smoke:
    bash scripts/runtime-smoke.sh

[doc('Show bounded read-only status for one Argo Application')]
status-app APP:
    bash scripts/status-app.sh "{{APP}}"

[doc('Collect bounded downstream diagnostics for one Argo Application')]
diagnose-app APP:
    bash scripts/diagnose-app.sh "{{APP}}"

[doc('Audit runtime PVC/CNPG coverage by Velero/Barman')]
backup-audit:
    bash scripts/backup-audit.sh

[doc('Capture a metadata-only Argo orphan inventory; never mutates the cluster')]
argo-orphan-inventory OUTPUT:
    bash scripts/argo-orphan-inventory.sh --output "{{OUTPUT}}"

[doc('Compare a fresh metadata-only Argo orphan inventory with a baseline')]
argo-orphan-compare BASELINE OUTPUT:
    bash scripts/argo-orphan-inventory.sh --compare "{{BASELINE}}" --output "{{OUTPUT}}"

[doc('List curated browser USER-level tests')]
e2e-list:
    cd tests/e2e && npm run list
