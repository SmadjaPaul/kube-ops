#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?KUBECONFIG must point to the kubeconfig handed off by homelab-infra}"
: "${DOPPLER_CLUSTER_TOKEN:?DOPPLER_CLUSTER_TOKEN must contain the read-only cluster/prd service token}"

for cmd in kubectl kustomize; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd is required" >&2
    exit 2
  }
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

apply_root() {
  local root="$1"
  echo "==> apply $root"
  kustomize build --enable-helm "$root" |
    kubectl apply --server-side --force-conflicts -f -
}

echo "==> verify Kubernetes API"
kubectl version >/dev/null
kubectl get nodes -o wide

echo "==> install Gateway API v1.4.1 CRDs required by Cilium 1.19.4"
gateway_api_base="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard"
for crd in   gateway.networking.k8s.io_gatewayclasses.yaml   gateway.networking.k8s.io_gateways.yaml   gateway.networking.k8s.io_httproutes.yaml   gateway.networking.k8s.io_referencegrants.yaml   gateway.networking.k8s.io_grpcroutes.yaml
do
  kubectl apply --server-side -f "$gateway_api_base/$crd"
done

echo "==> bootstrap Cilium"
apply_root k8s/infrastructure/network/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m

echo "==> wait for node networking"
kubectl wait --for=condition=Ready node --all --timeout=10m

echo "==> bootstrap cert-manager"
apply_root k8s/infrastructure/controllers/cert-manager
kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager --timeout=5m
kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout=5m
kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-cainjector --timeout=5m

echo "==> bootstrap External Secrets"
apply_root k8s/infrastructure/controllers/external-secrets
kubectl -n external-secrets wait --for=condition=Available deployment/external-secrets --timeout=5m
kubectl -n external-secrets wait --for=condition=Available deployment/external-secrets-webhook --timeout=5m
kubectl -n external-secrets wait --for=condition=Available deployment/external-secrets-cert-controller --timeout=5m

echo "==> install read-only Doppler runtime token"
kubectl -n external-secrets create secret generic doppler-access-token   --from-literal=token="$DOPPLER_CLUSTER_TOKEN"   --dry-run=client -o yaml |
  kubectl apply -f -

echo "==> wait for Doppler ClusterSecretStore"
for _ in $(seq 1 60); do
  status="$(kubectl get clustersecretstore doppler-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$status" == "True" ]] && break
  sleep 5
done
[[ "$(kubectl get clustersecretstore doppler-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]] || {
  echo "ERROR: ClusterSecretStore/doppler-cluster is not Ready" >&2
  exit 1
}

echo "==> bootstrap Argo CD"
apply_root k8s/infrastructure/controllers/argocd
kubectl -n argocd wait --for=condition=Available deployment/argocd-server --timeout=10m
kubectl -n argocd wait --for=condition=Available deployment/argocd-repo-server --timeout=10m
kubectl -n argocd wait --for=condition=Available deployment/argocd-applicationset-controller --timeout=10m

echo "==> hand desired-state ownership to Argo CD"
kubectl apply --server-side -f k8s/infrastructure/project.yaml
kubectl apply --server-side -f k8s/infrastructure/application-set.yaml
kubectl apply --server-side -f k8s/applications/project.yaml
kubectl apply --server-side -f k8s/applications/application-set.yaml

echo "==> bootstrap complete"
echo "Argo CD now owns steady-state reconciliation. Do not continue with imperative application applies."
