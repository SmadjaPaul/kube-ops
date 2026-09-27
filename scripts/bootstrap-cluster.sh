#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for cmd in kubectl kustomize; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd is required" >&2
    exit 2
  }
done

: "${DOPPLER_TOKEN:?set DOPPLER_TOKEN to the read-only cluster/prd ESO service token}"

kubectl get --raw=/readyz >/dev/null

apply_root() {
  local root=$1
  echo "== bootstrap: $root =="
  kustomize build --enable-helm "$root" |
    kubectl apply --server-side --force-conflicts -f -
}

apply_root k8s/infrastructure/network/gateway-api-crds
apply_root k8s/infrastructure/network/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m

apply_root k8s/infrastructure/controllers/external-secrets
kubectl -n external-secrets rollout status deployment/external-secrets --timeout=5m

token_file="$(mktemp)"
trap 'rm -f "$token_file"' EXIT
chmod 600 "$token_file"
printf '%s' "$DOPPLER_TOKEN" >"$token_file"
kubectl create secret generic doppler-access-token   --namespace external-secrets   --from-file=token="$token_file"   --dry-run=client -o yaml |
  kubectl apply --server-side -f -
rm -f "$token_file"
trap - EXIT

apply_root k8s/infrastructure/controllers/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m

apply_root k8s/infrastructure/controllers/argocd
kubectl -n argocd rollout status deployment/argocd-server --timeout=5m
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=5m
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=5m

kubectl apply --server-side -f k8s/infrastructure/project.yaml
kubectl apply --server-side -f k8s/infrastructure/application-set.yaml
kubectl apply --server-side -f k8s/applications/project.yaml
kubectl apply --server-side -f k8s/applications/application-set.yaml

echo "BOOTSTRAP_COMPLETE=PASS"
echo "Steady state is now Git -> Argo CD -> Kubernetes."
