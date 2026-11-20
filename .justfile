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

[doc('Regenerate the Backstage catalog from Git (catalog/generated/all.yaml)')]
catalog-generate:
    node scripts/catalog/generate-catalog.mjs

[doc('Run deterministic clusterless V1 + backup validation')]
check:
    npm run check:local

[doc('Kyverno static gate: render roots, apply ValidatingPolicy, ratchet against policy/baseline.tsv')]
policy-check:
    bash scripts/policy-check.sh
    bash scripts/policy-check.sh --tests

[doc('Tighten policy/baseline.tsv after fixing violations (full render only)')]
policy-baseline-update:
    bash scripts/policy-check.sh --update

[doc('Run validators only for Git-diff affected Kustomize components')]
check-affected:
    bash -n scripts/check-agent-harness-contract.sh scripts/check-v1-active-contract.sh scripts/backup-static-contract.sh
    bash tests/harness/argo-orphan-contract-test.sh
    bash tests/harness/runtime-smoke-test.sh
    bash tests/harness/invoice-restore-isolation-test.sh
    bash tests/harness/velero-storage-tier-test.sh
    bash tests/harness/longhorn-servicemonitor-contract-test.sh
    bash tests/harness/longhorn-tier-restore-runbook-test.sh
    bash tests/harness/d-recovery-contract-test.sh
    bash tests/harness/mastra-factory-readiness-test.sh
    bash tests/harness/mastra-factory-checkpoint-s3-contract-test.sh
    bash tests/harness/mastra-sandbox-tmp-contract-test.sh
    bash tests/harness/mastra-factory-promotion-test.sh
    npm run check:agent-harness
    bash scripts/affected-tests.sh

[doc('Validate canonical operator Kubernetes access; auto-bootstrap from Doppler, never from ~/.kube')]
kube-access-check:
    bash -c 'source scripts/lib/kube-preflight.sh; require_kube_access'

[doc('Read-only Argo/Gateway/workload runtime inventory')]
runtime-inventory:
    bash scripts/runtime-inventory.sh

[doc('Probe every discovered internal HTTPRoute; OUTPUT=summary|errors|full')]
runtime-smoke OUTPUT="summary":
    OUTPUT="{{OUTPUT}}" bash scripts/runtime-smoke.sh
    if [ "{{OUTPUT}}" = full ]; then bash scripts/github-queued-runs-check.sh; else bash scripts/github-queued-runs-check.sh | sed -n 1p; fi

[doc('Show bounded read-only status for one Argo Application; OUTPUT=summary|errors|full')]
status-app APP OUTPUT="summary":
    bash scripts/status-app.sh "{{APP}}" "{{OUTPUT}}"

[doc('Collect bounded downstream diagnostics for one Argo Application; OUTPUT=summary|errors|full')]
diagnose-app APP OUTPUT="summary":
    bash scripts/diagnose-app.sh "{{APP}}" "{{OUTPUT}}"

[doc('Audit runtime PVC/CNPG coverage by Velero/Barman')]
backup-audit:
    bash scripts/backup-audit.sh

[doc('Regenerate the Git-only PVC backup coverage table (needs kustomize and helm)')]
backup-coverage-static:
    python3 scripts/backup-coverage-static.py --output docs/operations/backup-coverage-static.md

[doc('Capture a metadata-only Argo orphan inventory; never mutates the cluster')]
argo-orphan-inventory OUTPUT:
    bash scripts/argo-orphan-inventory.sh --output "{{OUTPUT}}"

[doc('Compare a fresh metadata-only Argo orphan inventory with a baseline')]
argo-orphan-compare BASELINE OUTPUT:
    bash scripts/argo-orphan-inventory.sh --compare "{{BASELINE}}" --output "{{OUTPUT}}"

[doc('List curated browser USER-level tests')]
e2e-list:
    cd tests/e2e && npm run list

[doc('Run offline documentation integrity checks and negative fixtures')]
docs-check:
    node scripts/check-documentation-integrity.mjs
    node --test tests/harness/documentation-integrity-test.mjs

[doc('Build the Docusaurus site with broken links rejected by configuration')]
docs-build:
    cd website && npm run build

[doc('Post-merge PASS/FAIL for one app on one cluster (homelab|oracle-a1) from Grafana Cloud, no cluster access')]
verify-delivery CLUSTER APP *ARGS:
    bash scripts/verify-delivery.sh "{{CLUSTER}}" "{{APP}}" {{ARGS}}

[doc('Deliver a shared base on oracle-a1: overlay + Application + root entry; BASE_REL is under k8s/applications')]
scaffold-oke-app BASE_REL NAME NAMESPACE:
    bash scripts/scaffold-oke-app.sh "{{BASE_REL}}" "{{NAME}}" "{{NAMESPACE}}"
