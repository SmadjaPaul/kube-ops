#!/usr/bin/env bash
# Bootstrap de l'Argo CD d'OKE (oracle-a1) : une commande, idempotente (PLT-405, D-2026-11-21-01).
#
#   bash scripts/oke-bootstrap.sh --kubeconfig <fichier> [--context <nom>] [--dry-run]
#
# Rend k8s/clusters/oracle-a1/bootstrap (kustomize --enable-helm, Argo CD v3.5.1) puis l'applique en
# server-side apply, en trois temps : namespace + CRD + Argo CD, attente des CRD, puis projet
# `bootstrap` et Application `root`. La suite (projets, ApplicationSets, baseline) vient de Git :
# la root se reconcilie seule depuis k8s/clusters/oracle-a1/argocd-root.
#
# Rejouable : un second passage ne change rien (server-side apply). Aucun secret n'est lu, cree ou
# affiche : le kubeconfig n'est jamais ouvert par ce script (seul kubectl le lit), le Secret
# argocd-initial-admin-secret n'est pas touche. --dry-run rend et valide cote client, sans ecrire.
# Prerequis : kubectl, kustomize (avec helm), yq ; acces reseau vers l'API privee d'OKE (bastion
# ou NetBird) et vers argoproj.github.io (rendu du chart).
set -euo pipefail

usage() { echo "usage: $0 --kubeconfig <fichier> [--context <nom>] [--dry-run]" >&2; exit 2; }

kubeconfig="" context="" dry_run=0
while (($#)); do
  case "$1" in
    --kubeconfig) [[ $# -ge 2 ]] || usage; kubeconfig="$2"; shift 2 ;;
    --context) [[ $# -ge 2 ]] || usage; context="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
[[ -n $kubeconfig ]] || usage
[[ -f $kubeconfig ]] || { echo "ERROR: kubeconfig file not found: $kubeconfig" >&2; exit 2; }
for t in kubectl kustomize yq; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t is required" >&2; exit 2; }
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
dir="$repo/k8s/clusters/oracle-a1/bootstrap"
[[ -f $dir/kustomization.yaml ]] || { echo "ERROR: $dir not found" >&2; exit 2; }

export KUBECONFIG="$kubeconfig"
k=(kubectl)
[[ -z $context ]] || k+=(--context "$context")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Garde-fou : on annonce la cible (nom de contexte seulement) et on exige qu'elle reponde.
if ((!dry_run)); then
  ctx="$("${k[@]}" config current-context 2>/dev/null || true)"
  [[ -n $ctx ]] || { echo "ERROR: no current context in the kubeconfig (pass --context)" >&2; exit 2; }
  echo "TARGET context=$ctx (expected: the OKE cluster oracle-a1, k8s v1.36, 1 arm64 node)"
  "${k[@]}" get --raw /readyz >/dev/null || { echo "ERROR: the API server does not answer (private API: open the bastion or NetBird path first)" >&2; exit 1; }
fi

echo "RENDER $dir"
kustomize build --enable-helm "$dir" >"$tmp/all.yaml"
# Les Application / AppProject ont besoin de leurs CRD : on les applique apres l'attente.
yq eval 'select(.kind != "Application" and .kind != "AppProject")' "$tmp/all.yaml" >"$tmp/early.yaml"
yq eval 'select(.kind == "Application" or .kind == "AppProject")' "$tmp/all.yaml" >"$tmp/late.yaml"
[[ -s $tmp/early.yaml && -s $tmp/late.yaml ]] || { echo "ERROR: rendered bootstrap is empty or incomplete" >&2; exit 1; }

if ((dry_run)); then
  echo "DRY-RUN objects=$(yq eval --no-doc '.kind' "$tmp/all.yaml" | grep -c .) (nothing applied, API not contacted)"
  yq eval --no-doc '.kind + "/" + .metadata.name' "$tmp/late.yaml"
  exit 0
fi

echo "APPLY namespace, CRDs and Argo CD"
"${k[@]}" apply --server-side -f "$tmp/early.yaml"
for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
  "${k[@]}" wait --for=condition=Established --timeout=120s "crd/$crd"
done
echo "APPLY bootstrap project and root Application"
"${k[@]}" apply --server-side -f "$tmp/late.yaml"

echo "WAIT Argo CD workloads"
"${k[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for d in argocd-repo-server argocd-server argocd-applicationset-controller; do
  "${k[@]}" -n argocd rollout status "deployment/$d" --timeout=300s
done

echo "STATE (names and status only)"
"${k[@]}" -n argocd get applications,applicationsets,appprojects
echo "NEXT: the root reconciles k8s/clusters/oracle-a1/argocd-root from main; check 'infra-guardrails' becomes Synced/Healthy."
