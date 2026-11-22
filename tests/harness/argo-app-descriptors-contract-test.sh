#!/usr/bin/env bash
# Contrat de scripts/check-argo-app-descriptors.sh (PLT-394) : descripteurs `argocd-app.yaml`
# crees dans un depot temporaire (jamais dans le depot reel), sur le domaine `tools`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo_root/scripts/check-argo-app-descriptors.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

fresh() { # depot de travail minimal : racine Argo + domaine tools
  rm -rf "$tmp/w" && mkdir -p "$tmp/w/k8s/applications" "$tmp/w/k8s/bootstrap"
  cp -R "$repo_root/k8s/bootstrap/argocd-root" "$tmp/w/k8s/bootstrap/argocd-root"
  mkdir -p "$tmp/w/k8s/clusters/oracle-a1"
  cp -R "$repo_root/k8s/clusters/oracle-a1/argocd-root" "$tmp/w/k8s/clusters/oracle-a1/argocd-root"
  cp -R "$repo_root/k8s/applications/tools" "$tmp/w/k8s/applications/tools"
  # le domaine reel porte aussi l'app pilote OKE (whoami) : les cas ci-dessous partent de it-tools seul
  rm -rf "$tmp/w/k8s/applications/tools/whoami"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n\nresources:\n- it-tools\n' >"$tmp/w/k8s/applications/tools/kustomization.yaml"
}

descriptor() {
  cat >"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml" <<'YAML'
name: it-tools
namespace: it-tools
postMerge: revert
preview: true
extraPaths: []
YAML
}

run() { bash "$check" "$tmp/w" >"$tmp/out" 2>&1; }
expect_fail() { # <motif> <message>
  if run; then cat "$tmp/out" >&2; fail "$2: must be rejected"; fi
  grep -qF -- "$1" "$tmp/out" || { cat "$tmp/out" >&2; fail "$2: expected message '$1'"; }
}

oke_descriptor() { # descripteur OKE de it-tools ; remplace le descripteur homelab
  rm -f "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
  cat >"$tmp/w/k8s/applications/tools/it-tools/argocd-app.oracle-a1.yaml" <<'YAML'
name: it-tools
namespace: it-tools
cluster: oracle-a1
postMerge: notify
YAML
}
oke_file="$tmp/w/k8s/applications/tools/it-tools/argocd-app.oracle-a1.yaml"

# 0. depot reel : aucun descripteur, le controle passe
bash "$check" "$repo_root" >"$tmp/out" 2>&1 || { cat "$tmp/out" >&2; fail "real repository must pass"; }

# 1. domaine tools complet (it-tools), retire de `applications` : passe, equivalence de rendu incluse
fresh; descriptor
run || { cat "$tmp/out" >&2; fail "complete tools domain must pass"; }
grep -q '1 descriptor' "$tmp/out" || fail "descriptor not counted"

# 2. valeurs par defaut : seuls name et namespace sont obligatoires
printf 'name: it-tools\nnamespace: it-tools\n' >"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
run || { cat "$tmp/out" >&2; fail "minimal descriptor must pass"; }

# 3. schema
fresh; descriptor
sed -i.bak 's/^name: it-tools/name: It_Tools/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "is not DNS-1123" "invalid name"
expect_fail "must equal the app directory" "name differs from folder"
fresh; descriptor; echo 'surprise: 1' >>"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "unknown field 'surprise'" "unknown field"
fresh; descriptor; sed -i.bak 's/^postMerge: revert/postMerge: maybe/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "postMerge must be" "postMerge value"
fresh; descriptor; sed -i.bak 's/^preview: true/preview: "yes"/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "preview must be true or false" "preview type"
# preview: true : l'app ne doit rendre que des kinds admis par l'AppProject previews
fresh; descriptor
cat >"$tmp/w/k8s/applications/tools/it-tools/np.yaml" <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: extra
  namespace: it-tools
spec:
  endpointSelector: {}
YAML
printf -- '- np.yaml\n' >>"$tmp/w/k8s/applications/tools/it-tools/kustomization.yaml"
expect_fail "which AppProject previews does not admit" "preview true with a kind the previews project refuses"
fresh; descriptor; sed -i.bak 's/^namespace: it-tools/namespace: elsewhere/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "is not among the namespaces rendered" "namespace absent from render"
fresh; descriptor; echo 'project: nope' >>"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "project 'nope' is not an AppProject" "unknown project"
fresh; descriptor; echo 'project: bootstrap' >>"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "is not a destination of AppProject 'bootstrap'" "project that does not admit the namespace"

# 4. extraPaths
fresh; descriptor; sed -i.bak 's/^extraPaths: \[\]/extraPaths: [k8s\/applications\/media\/shared]/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "extraPaths entry 'k8s/applications/media/shared' does not exist" "missing extraPaths"
mkdir -p "$tmp/w/k8s/applications/media/shared"; : >"$tmp/w/k8s/applications/media/shared/x.yaml"
run || { cat "$tmp/out" >&2; fail "existing extraPaths must pass"; }
fresh; descriptor; sed -i.bak 's/^extraPaths: \[\]/extraPaths: ["\/etc"]/' "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "must be a plain path from the repository root" "absolute extraPaths"

# 5. descripteur liste dans une kustomization, ou mal place
fresh; descriptor; echo '- it-tools/argocd-app.yaml' >>"$tmp/w/k8s/applications/tools/kustomization.yaml"
expect_fail "must not be listed in a kustomization" "descriptor in kustomization"
fresh; descriptor; descriptor_copy="$tmp/w/k8s/applications/tools/argocd-app.yaml"; cp "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml" "$descriptor_copy"
expect_fail "must be exactly k8s/applications/<domaine>/<app>/argocd-app.yaml" "misplaced descriptor"

# 8. equivalence : objet de niveau domaine perdu, transformation de domaine non reproduite, objet partage
fresh; descriptor
cp "$tmp/w/k8s/applications/tools/it-tools/namespace.yaml" "$tmp/w/k8s/applications/tools/extra-ns.yaml"
sed -i.bak 's/name: it-tools/name: orphan-ns/' "$tmp/w/k8s/applications/tools/extra-ns.yaml"; rm -f "$tmp/w/k8s/applications/tools/extra-ns.yaml.bak"
echo '- extra-ns.yaml' >>"$tmp/w/k8s/applications/tools/kustomization.yaml"
expect_fail "Namespace||orphan-ns is rendered by the domain but by no app" "domain-level file"

fresh; descriptor
printf 'labels:\n  - pairs:\n      team: tools\n    includeSelectors: false\n' >>"$tmp/w/k8s/applications/tools/kustomization.yaml"
expect_fail "differs between the domain render and the app render" "domain-level transformation"

# 9. OKE : descripteur argocd-app.oracle-a1.yaml (meme domaine migre, l'app n'a qu'un cluster)
fresh; oke_descriptor
run || { cat "$tmp/out" >&2; fail "valid oracle-a1 descriptor must pass"; }
grep -q '1 on oracle-a1' "$tmp/out" || fail "oracle-a1 descriptor not counted"
fresh; oke_descriptor; printf 'name: it-tools\nnamespace: it-tools\ncluster: oracle-a1\n' >"$oke_file"
run || { cat "$tmp/out" >&2; fail "minimal oracle-a1 descriptor must pass"; }
fresh; oke_descriptor; sed -i.bak '/^cluster:/d' "$oke_file"
expect_fail "cluster must be 'oracle-a1'" "missing cluster"
fresh; oke_descriptor; sed -i.bak 's/^cluster: oracle-a1/cluster: homelab/' "$oke_file"
expect_fail "cluster must be 'oracle-a1'" "cluster differs from the file suffix"
fresh; oke_descriptor; sed -i.bak 's/^postMerge: notify/postMerge: revert/' "$oke_file"
expect_fail "postMerge must be 'notify' on oracle-a1" "revert on oracle-a1"
fresh; oke_descriptor; echo 'preview: true' >>"$oke_file"
expect_fail "preview is homelab-only" "preview on oracle-a1"
fresh; oke_descriptor; echo 'surprise: 1' >>"$oke_file"
expect_fail "unknown field 'surprise'" "unknown field on oracle-a1"
# un champ `cluster` n'existe pas dans le descripteur homelab
fresh; descriptor; echo 'cluster: oracle-a1' >>"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "unknown field 'cluster'" "cluster on a homelab descriptor"
# jamais les deux fichiers : une app, un cluster
fresh; descriptor; cp "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml" "$tmp/x.yaml"; oke_descriptor; cp "$tmp/x.yaml" "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "an app runs on one cluster at a time" "both descriptors"
# projet inconnu de la racine OKE, namespace refuse par le projet OKE
fresh; oke_descriptor; echo 'project: previews' >>"$oke_file"
expect_fail "project 'previews' is not an AppProject of k8s/clusters/oracle-a1/argocd-root" "homelab-only project on oracle-a1"
fresh; oke_descriptor; sed -i.bak 's/^namespace: it-tools/namespace: elsewhere/' "$oke_file"
expect_fail "is not among the namespaces rendered" "oracle-a1 namespace absent from render"
fresh; oke_descriptor; sed -i.bak 's/name: it-tools/name: monitoring/' "$tmp/w/k8s/applications/tools/it-tools/namespace.yaml"; sed -i.bak 's/^namespace: it-tools/namespace: monitoring/' "$oke_file"
grep -rl 'namespace: it-tools' "$tmp/w/k8s/applications/tools/it-tools" | xargs sed -i.bak 's/namespace: it-tools/namespace: monitoring/'
expect_fail "rendered namespace 'monitoring' is not a destination of AppProject 'apps'" "oracle-a1 infrastructure namespace"
# projet apps d'OKE : doit refuser argocd
fresh; oke_descriptor; yq eval -i 'del(.spec.destinations[] | select(.namespace == "!argocd"))' "$tmp/w/k8s/clusters/oracle-a1/argocd-root/apps-project.yaml"
expect_fail "AppProject apps (oracle-a1) must deny namespace 'argocd'" "oracle-a1 apps project allowing argocd"
# descripteur OKE mal place ou suffixe inconnu
fresh; oke_descriptor; cp "$oke_file" "$tmp/w/k8s/applications/tools/argocd-app.oracle-a1.yaml"
expect_fail "descriptor must be exactly k8s/applications/<domaine>/<app>/argocd-app.yaml" "misplaced oracle-a1 descriptor"
fresh; descriptor; cp "$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml" "$tmp/w/k8s/applications/tools/it-tools/argocd-app.oracle.yaml"
expect_fail "argocd-app.oracle.yaml: descriptor must be exactly" "unknown cluster suffix"
fresh; oke_descriptor; echo '- it-tools/argocd-app.oracle-a1.yaml' >>"$tmp/w/k8s/applications/tools/kustomization.yaml"
expect_fail "must not be listed in a kustomization" "oracle-a1 descriptor in kustomization"
# --- PLT-407 : pas de donnees durables sur OKE, sauf `disposableData` justifie
d="$tmp/w/k8s/applications/tools/it-tools"
add_res() { # <fichier> : ajoute un manifeste a la kustomization de it-tools (lue du stdin)
  cat >"$d/$1"; printf -- '- %s\n' "$1" >>"$d/kustomization.yaml"
}
pvc() { add_res pvc.yaml <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: it-tools
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: oci-bv
  resources:
    requests:
      storage: 1Gi
YAML
}
fresh; oke_descriptor; pvc
expect_fail "renders durable data on oracle-a1 (PersistentVolumeClaim/data)" "OKE app with a PVC"
fresh; oke_descriptor; pvc; echo 'disposableData: "cache SQLite recreable au demarrage, aucune donnee utilisateur"' >>"$oke_file"
run || { cat "$tmp/out" >&2; fail "OKE app with a PVC and a justified disposableData must pass"; }
fresh; oke_descriptor; pvc; echo 'disposableData: ""' >>"$oke_file"
expect_fail "disposableData must be a non-empty string" "OKE disposableData empty"
fresh; oke_descriptor; pvc; echo 'disposableData: true' >>"$oke_file"
expect_fail "disposableData must be a non-empty string" "OKE disposableData not a string"
fresh; oke_descriptor; echo 'disposableData: "sans objet durable"' >>"$oke_file"
expect_fail "disposableData is declared but" "OKE stale exception without durable object"
fresh; oke_descriptor; add_res sts.yaml <<'YAML'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: it-tools
spec:
  serviceName: db
  selector: {matchLabels: {a: b}}
  template: {metadata: {labels: {a: b}}, spec: {containers: [{name: c, image: x}]}}
  volumeClaimTemplates:
  - metadata: {name: data}
    spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
YAML
expect_fail "StatefulSet/db" "OKE StatefulSet with volumeClaimTemplates"
fresh; oke_descriptor; add_res pg.yaml <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: it-tools
spec:
  instances: 1
  storage: {size: 1Gi}
YAML
expect_fail "Cluster/pg" "OKE CNPG Cluster"
# un StatefulSet sans volumeClaimTemplates n'est pas une donnee durable
fresh; oke_descriptor; add_res sts.yaml <<'YAML'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: stateless
  namespace: it-tools
spec:
  serviceName: s
  selector: {matchLabels: {a: b}}
  template: {metadata: {labels: {a: b}}, spec: {containers: [{name: c, image: x}]}}
YAML
run || { cat "$tmp/out" >&2; fail "StatefulSet without volumeClaimTemplates must pass on OKE"; }
# homelab inchange : le champ n'existe pas la-bas et un PVC y est normal
fresh; descriptor; pvc
run || { cat "$tmp/out" >&2; fail "homelab app with a PVC must still pass"; }
fresh; descriptor; echo 'disposableData: "x"' >>"$tmp/w/k8s/applications/tools/it-tools/argocd-app.yaml"
expect_fail "unknown field 'disposableData'" "disposableData is OKE-only"

echo "OK: argocd-app.yaml descriptor contract"
