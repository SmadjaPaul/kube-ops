#!/usr/bin/env bash
# Session administrateur OKE (oracle-a1) pour Paul, sans kubeconfig stocké (PLT-480).
#
# Le kubeconfig admin n'est pas dans Doppler : il est généré à la volée par
# `oci ce cluster create-kubeconfig` à partir de la clé API OCI de Paul
# (Doppler infrastructure/prd OCI_CLI_*), sur le point d'accès privé de l'API
# (10.0.x.y, joignable par NetBird). Il vit dans un dossier temporaire supprimé
# à la sortie ; le jeton est demandé à OCI à chaque appel kubectl (exec).
#
# Usage (par Paul, NetBird connecté) :
#   bash scripts/oke-admin.sh kubectl -n argocd get applications.argoproj.io
#   bash scripts/oke-admin.sh bash scripts/agent-operator-oke-token.sh --provision
# La sortie passe par le masque de doppler-safe.sh : pas de shell interactif.
#
# Réservé à Paul : les agents lisent OKE par `scripts/kubectl-ro.sh --cluster oracle-a1`.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OKE_CLUSTER_NAME=${OKE_CLUSTER_NAME:-oracle-a1}
KEYS=OCI_CLI_USER,OCI_CLI_TENANCY,OCI_CLI_FINGERPRINT,OCI_CLI_KEY_CONTENT,OCI_CLI_REGION,OCI_COMPARTMENT_ID

if [ "${OKE_ADMIN_INNER:-}" != 1 ]; then
  command -v oci >/dev/null || { echo "oke-admin: CLI oci manquante (brew install oci-cli)" >&2; exit 2; }
  command -v kubectl >/dev/null || { echo "oke-admin: kubectl manquant" >&2; exit 2; }
  # Les identifiants OCI ne sont injectés que dans ce processus, jamais affichés.
  exec env OKE_ADMIN_INNER=1 bash "$HERE/doppler-safe.sh" run --only "$KEYS" -- bash "$HERE/oke-admin.sh" "$@"
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/oke-admin.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

cluster_id=$(oci ce cluster list --compartment-id "$OCI_COMPARTMENT_ID" --name "$OKE_CLUSTER_NAME" \
  --lifecycle-state ACTIVE --query 'data[0].id' --raw-output)
[ -n "$cluster_id" ] && [ "$cluster_id" != null ] || {
  echo "oke-admin: cluster $OKE_CLUSTER_NAME introuvable ou pas ACTIVE" >&2
  exit 3
}

oci ce cluster create-kubeconfig --cluster-id "$cluster_id" --file "$work/kubeconfig" \
  --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT --overwrite >/dev/null
export KUBECONFIG="$work/kubeconfig"

server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "oke-admin: session admin $OKE_CLUSTER_NAME ($server), kubeconfig temporaire supprimé à la sortie" >&2
kubectl --request-timeout=15s version -o json >/dev/null 2>&1 || {
  echo "oke-admin: API $server injoignable : NetBird est-il connecté ?" >&2
  exit 4
}

[ "$#" -ge 1 ] || { echo "oke-admin: commande manquante (ex. kubectl -n argocd get applications.argoproj.io)" >&2; exit 2; }
"$@"
