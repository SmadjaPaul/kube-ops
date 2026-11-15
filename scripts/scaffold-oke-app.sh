#!/usr/bin/env bash
# Deliver a shared base on oracle-a1: one command creates the overlay folder, the
# Application and its line in the Oracle root (k8s/clusters/oracle-a1/apps).
# Usage: bash scripts/scaffold-oke-app.sh BASE_REL NAME NAMESPACE
#   BASE_REL  path under k8s/applications, e.g. tools/foo
# Refuses a base that holds data (PVC, volumeClaimTemplates, CNPG Cluster):
# k8s/clusters/oracle-a1/README.md forbids data on Oracle until PLT-190.
# Run `just check` afterwards. Merge the PR; verify with `just verify-delivery oracle-a1 NAME`.
set -euo pipefail
root=${SCAFFOLD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
base_rel=${1:?usage: scaffold-oke-app.sh BASE_REL NAME NAMESPACE}; name=${2:?name}; ns=${3:?namespace}
[[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $ns =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: invalid name or namespace" >&2; exit 2; }
[[ $base_rel != *..* && $base_rel != /* ]] || { echo "ERROR: BASE_REL must stay under k8s/applications" >&2; exit 2; }
base="$root/k8s/applications/$base_rel"
[[ -f $base/kustomization.yaml ]] || { echo "ERROR: no kustomization at k8s/applications/$base_rel" >&2; exit 2; }
# Data scan: the rendered manifests when kustomize is available (follows every resource
# reference), else the base folder only. Quoted kinds are matched too.
kind_re='^[[:space:]]*kind:[[:space:]]*["'"'"']?(PersistentVolumeClaim|Cluster)["'"'"']?[[:space:]]*$|volumeClaimTemplates'
# Fail closed: a scan of the base folder alone would miss data pulled in by `resources` references.
command -v kustomize >/dev/null || { echo "BLOCKED: kustomize is required to scan the rendered base for data (PVC/CNPG)." >&2; exit 2; }
rendered=$(kustomize build --enable-helm "$base" 2>/dev/null) || { echo "ERROR: kustomize build failed for $base_rel" >&2; exit 2; }
scan_hit=0; grep -Eqs "$kind_re" <<<"$rendered" && scan_hit=1
if (( scan_hit )); then
  echo "BLOCKED: base holds data (PVC/CNPG). No data on Oracle before PLT-190 (clusters/oracle-a1/README.md)." >&2; exit 1
fi
# The AppProject is bootstrap-only (not synced by the Oracle Argo CD): an unlisted namespace
# needs a project.yaml change applied once by the operator (exec:local), so refuse here.
if ! grep -Eqs "^[[:space:]]*-[[:space:]]*\{[^}]*namespace: $ns\}" "$root/k8s/clusters/oracle-a1/bootstrap/project.yaml"; then
  echo "BLOCKED: namespace $ns is not a destination of AppProject oracle-a1. Add it to bootstrap/project.yaml and ask for the one-time bootstrap apply (exec:local ticket), then rerun." >&2; exit 1
fi
dir="$root/k8s/clusters/oracle-a1/$name"; app="$root/k8s/clusters/oracle-a1/apps/$name.yaml"
[[ ! -e $dir && ! -e $app ]] || { echo "ERROR: $name already exists on oracle-a1" >&2; exit 1; }
mkdir -p "$dir"
cat >"$dir/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
YAML
cat >"$dir/kustomization.yaml" <<YAML
# Oracle overlay of the shared base applications/$base_rel (no copied manifests).
# Homelab-only parts (Gateway routes, Cilium policies, LAN hosts) are removed with patches here.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $ns
resources:
  - namespace.yaml
  - ../../../applications/$base_rel
YAML
cat >"$app" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: oracle-a1
  source:
    repoURL: https://github.com/SmadjaPaul/kube-ops.git
    targetRevision: main
    path: k8s/clusters/oracle-a1/$name
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
YAML
printf '  - %s.yaml\n' "$name" >>"$root/k8s/clusters/oracle-a1/apps/kustomization.yaml"
echo "CREATED k8s/clusters/oracle-a1/$name/ and apps/$name.yaml; registered in apps/kustomization.yaml"
