#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd is required" >&2
    exit 2
  }
done

kubectl cluster-info >/dev/null

echo "== Gateway API v1.6.1 =="
kubectl apply --server-side --field-manager=kube-ops-bootstrap   -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=120s
kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=120s

echo "== Cilium 1.20.2 =="
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm upgrade --install cilium cilium/cilium   --version 1.20.2   --namespace kube-system   -f k8s/infrastructure/network/cilium/values.yaml   --wait --timeout 10m
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m

echo "== External Secrets 2.6.0 =="
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets   --version 2.6.0   --namespace external-secrets   --create-namespace   -f k8s/infrastructure/controllers/external-secrets/values.yaml   --wait --timeout 5m

if [[ -z "${DOPPLER_CLUSTER_TOKEN:-}" ]]; then
  command -v doppler >/dev/null 2>&1 || {
    echo "ERROR: set DOPPLER_CLUSTER_TOKEN or install/login to the Doppler CLI" >&2
    exit 2
  }
  DOPPLER_CLUSTER_TOKEN="$(doppler secrets get ESO_CLUSTER --project infrastructure --config prd --plain)"
fi
: "${DOPPLER_CLUSTER_TOKEN:?Doppler cluster service token is empty}"

kubectl -n external-secrets create secret generic doppler-access-token   --from-literal=token="$DOPPLER_CLUSTER_TOKEN"   --dry-run=client -o yaml |
  kubectl apply --server-side --field-manager=kube-ops-bootstrap -f -
unset DOPPLER_CLUSTER_TOKEN

kubectl apply --server-side --field-manager=kube-ops-bootstrap   -f k8s/infrastructure/controllers/external-secrets/doppler-store.yaml
kubectl wait --for=condition=Ready clustersecretstore/doppler-cluster --timeout=2m

echo "== cert-manager v1.20.2 =="
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager   --version v1.20.2   --namespace cert-manager   --create-namespace   -f k8s/infrastructure/controllers/cert-manager/values.yaml   --wait --timeout 5m
kubectl apply --server-side --field-manager=kube-ops-bootstrap   -f k8s/infrastructure/controllers/cert-manager/cert-manager-secrets-external.yaml   -f k8s/infrastructure/controllers/cert-manager/internal-ca-issuer.yaml   -f k8s/infrastructure/controllers/cert-manager/cloudflare-issuer.yaml
kubectl -n cert-manager wait --for=condition=Ready externalsecret/cert-manager-secrets --timeout=2m

echo "== Argo CD 10.3.3 =="
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
# Bootstrap Argo without Dex first. The steady-state Argo application later
# enables Dex from Git after ESO has populated argocd-secret. This avoids a
# first-boot dependency cycle between Argo readiness and its OIDC credential.
helm upgrade --install argocd argo/argo-cd   --version 10.3.3   --namespace argocd   --create-namespace   -f k8s/infrastructure/controllers/argocd/values.yaml   --set dex.enabled=false   --wait --timeout 10m

# Project the OIDC credential into the chart-created argocd-secret before Argo
# starts reconciling its own steady-state chart with Dex enabled.
kubectl apply --server-side --field-manager=kube-ops-bootstrap   -f k8s/infrastructure/controllers/argocd/externalsecret.yaml
kubectl -n argocd wait --for=condition=Ready externalsecret/argocd-secret --timeout=2m

echo "== Argo root handoff =="
kubectl apply --server-side --field-manager=kube-ops-bootstrap   -k k8s/bootstrap/argocd-root

echo "BOOTSTRAP=PASS"
echo "Argo CD now owns steady-state reconciliation from SmadjaPaul/kube-ops main."
