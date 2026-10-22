#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for cmd in kubectl doppler; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd is required" >&2
    exit 2
  }
done

kubectl cluster-info >/dev/null

# This is a one-time/recovery handoff, not a Kubernetes desired-state secret.
# The value is streamed from the authenticated operator Doppler session and is
# never printed, committed, or passed through the cluster/prd ESO token.
if [[ -z "${DOPPLER_ATLANTIS_TOKEN:-}" ]]; then
  DOPPLER_ATLANTIS_TOKEN="$(doppler secrets get ESO_ATLANTIS --project infrastructure --config prd --plain)"
fi
: "${DOPPLER_ATLANTIS_TOKEN:?Atlantis Doppler service token is empty}"

kubectl apply --server-side --field-manager=kube-ops-bootstrap \
  -f k8s/poc/atlantis-plan-only/atlantis-doppler-store.yaml >/dev/null

kubectl -n atlantis-system create secret generic atlantis-doppler-token \
  --from-literal=token="$DOPPLER_ATLANTIS_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply --server-side --field-manager=kube-ops-bootstrap -f - >/dev/null

unset DOPPLER_ATLANTIS_TOKEN
kubectl -n atlantis-system wait --for=condition=Ready secretstore/atlantis-doppler --timeout=2m
echo "ATLANTIS_DOPPLER_BOOTSTRAP=PASS"
