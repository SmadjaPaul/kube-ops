#!/usr/bin/env bash
# Echoue quand un namespace cible n'est pas une destination autorisee de l'AppProject Argo CD concerne.
#
# Cause des echecs "namespace X is not permitted in project Y" / InvalidSpecError constates apres merge
# (infra-previews/dns-exact-resolver, arc-runners-kube-ops) : la CI etait verte, la synchro Argo non.
#
#   1. ApplicationSet infrastructure : chaque namespace des manifestes rendus
#      (kind Namespace = metadata.name, autres objets = metadata.namespace) des chemins du generateur git
#      doit correspondre a une destination de template.spec.project.
#   1b. App of Apps infra-root (PLT-394) : meme controle pour le chemin source de chaque Application
#      de k8s/bootstrap/infra-root, contre son spec.project.
#   2. Applications imbriquees (kind: Application sous k8s/, hors bootstrap et clusters/) :
#      spec.destination.namespace doit correspondre a une destination du spec.project reference.
#
# Jokers : destination `*`, `pr-*`, `?` (glob bash). `namespace: ''` ne correspond qu'au namespace vide
# (il n'autorise donc rien d'explicite). Le projet `default` autorise tout.
#
# Usage : bash scripts/check-argo-project-namespaces.sh [racine-du-depot]   (defaut : depot courant)
# Lecture seule : aucun secret, aucun acces cluster.
set -euo pipefail

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 2; }
command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize is required" >&2; exit 2; }

repo="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
root_dir="$repo/k8s/bootstrap/argocd-root"
[[ -d $root_dir ]] || { echo "ERROR: $root_dir not found" >&2; exit 2; }

# shellcheck source=lib/argo-project-dest.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/argo-project-dest.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
errors=0

# Ecarts connus a la date d'introduction du controle (liste visible, jamais etendue en silence) :
# <projet><TAB><namespace><TAB><raison>. Une entree qui ne correspond plus a un ecart est une erreur
# (cliquet : on la retire quand l'ecart est corrige).
baseline="$repo/scripts/argo-project-namespaces.baseline.tsv"
baseline_keys="$tmp/baseline.keys"
: >"$tmp/baseline.seen"
if [[ -f $baseline ]]; then { grep -vE '^(#|$)' "$baseline" || true; } | cut -f1,2 >"$baseline_keys"; else : >"$baseline_keys"; fi

# --- AppProjects : <projet> -> destinations (une par ligne) --------------------------------
mkdir -p "$tmp/proj"
while IFS= read -r f; do
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    yq eval-all --no-doc "select(.kind == \"AppProject\" and .metadata.name == \"$name\") | .spec.destinations[] | .namespace // \"\"" "$f" \
      >"$tmp/proj/$name"
  done < <(yq eval-all --no-doc 'select(.kind == "AppProject") | .metadata.name' "$f")
done < <(grep -rlE '^kind: AppProject' "$repo/k8s" --include='*.yaml' 2>/dev/null | grep -v "^$repo/k8s/clusters/" | sort)

# 0 si le namespace $2 est autorise par le projet $1 (semantique : scripts/lib/argo-project-dest.sh)
allowed() {
  [[ $1 == default ]] && return 0
  argo_ns_allowed "$tmp/proj/$1" "$2"
}

# Verifie une liste "namespace<TAB>origine" ($1) pour le projet $2
check_list() {
  local file="$1" project="$2" ns origin
  [[ -f $tmp/proj/$project || $project == default ]] || {
    echo "FAIL: AppProject '$project' is not defined under k8s/ (needed by: $3)" >&2
    errors=$((errors + 1))
    return
  }
  sort -u "$file" | while IFS=$'\t' read -r ns origin; do
    [[ $ns == *'{{'* ]] && continue
    allowed "$project" "$ns" || {
      if grep -qxF "$project"$'\t'"$ns" "$baseline_keys"; then
        printf '%s\t%s\n' "$project" "$ns" >>"$tmp/baseline.seen"
        printf 'KNOWN (baseline): namespace "%s" is not a destination of AppProject "%s" (%s)\n' "$ns" "$project" "$origin" >&2
      else
        printf 'FAIL: namespace "%s" is not a destination of AppProject "%s" (%s)\n' "$ns" "$project" "$origin"
      fi
    }
  done >"$file.out"
  if [[ -s $file.out ]]; then
    cat "$file.out" >&2
    errors=$((errors + $(wc -l <"$file.out")))
  fi
}

render() {
  local dir="$1"
  if [[ -f $repo/scripts/lib/render-cache.sh && -e $repo/.git ]]; then
    # shellcheck source=lib/render-cache.sh
    (cd "$repo" && source scripts/lib/render-cache.sh && cat "$(render_root "${dir#"$repo"/}")")
  else
    kustomize build --enable-helm "$dir"
  fi
}

# --- 1. ApplicationSets -----------------------------------------------------------------------
appsets=("$root_dir/infrastructure-applicationset.yaml")
for appset in "${appsets[@]}"; do
  [[ -f $appset ]] || continue
  base="$(basename "$appset" .yaml)"
  project="$(yq eval '.spec.template.spec.project' "$appset")"
  : >"$tmp/$base.ns"
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    shopt -s nullglob
    for dir in $repo/$p; do
      [[ -f $dir/kustomization.yaml ]] || continue
      rel="${dir#"$repo"/}"
      if ! render "$dir" >"$tmp/rendered.yaml" 2>"$tmp/render.err"; then
        echo "FAIL: kustomize build failed for $rel" >&2
        sed 's/^/  /' "$tmp/render.err" >&2
        errors=$((errors + 1))
        continue
      fi
      yq eval --no-doc '
        select(.kind != null and .kind != "List") |
        (select(.kind == "Namespace") | .metadata.name + "\t" + "Namespace " + .metadata.name),
        (select(.kind != "Namespace" and .metadata.namespace != null) | .metadata.namespace + "\t" + .kind + "/" + .metadata.name)
      ' "$tmp/rendered.yaml" | sed "s|\$| in $rel (ApplicationSet $base)|" >>"$tmp/$base.ns"
    done
    shopt -u nullglob
  done < <(yq eval '.spec.generators[].git.directories[] | select(.exclude != true) | .path' "$appset")
  check_list "$tmp/$base.ns" "$project" "$base"
done

# --- 1b. App of Apps infra-root (PLT-394) ---------------------------------------------------
infra_root_dir="$repo/k8s/bootstrap/infra-root"
if [[ -d $infra_root_dir ]]; then
  while IFS=$'\t' read -r name project src; do
    [[ -n $name ]] || continue
    dir="$repo/$src"
    : >"$tmp/infra-root.$name.ns"
    if ! render "$dir" >"$tmp/rendered.yaml" 2>"$tmp/render.err"; then
      echo "FAIL: kustomize build failed for $src (Application $name, infra-root)" >&2
      sed 's/^/  /' "$tmp/render.err" >&2
      errors=$((errors + 1))
      continue
    fi
    yq eval --no-doc '
      select(.kind != null and .kind != "List") |
      (select(.kind == "Namespace") | .metadata.name + "\t" + "Namespace " + .metadata.name),
      (select(.kind != "Namespace" and .metadata.namespace != null) | .metadata.namespace + "\t" + .kind + "/" + .metadata.name)
    ' "$tmp/rendered.yaml" | sed "s|\$| in $src (Application $name, infra-root)|" >>"$tmp/infra-root.$name.ns"
    check_list "$tmp/infra-root.$name.ns" "$project" "Application $name"
  # yq eval (per document), not eval-all: eval-all crosses the documents and turned 7 Applications
  # into 7^5 = 16807 lines, one render each (V1 contract stuck for 30 min after #1863).
  done < <(yq eval --no-doc 'select(.kind == "Application") | .metadata.name + "\t" + (.spec.project // "default") + "\t" + .spec.source.path' "$infra_root_dir"/*.yaml)
fi

# --- 2. Applications imbriquees ---------------------------------------------------------------
: >"$tmp/nested.tsv"
while IFS= read -r f; do
  rel="${f#"$repo"/}"
  yq eval-all --no-doc '
    select(.kind == "Application" and .spec.destination.namespace != null) |
    (.spec.project // "default") + "\t" + .spec.destination.namespace + "\t" + .metadata.name
  ' "$f" | while IFS=$'\t' read -r project ns name; do
    printf '%s\t%s\t%s\n' "$project" "$ns" "Application $name in $rel" >>"$tmp/nested.tsv"
  done
done < <(grep -rlE '^kind: Application$' "$repo/k8s" --include='*.yaml' 2>/dev/null \
  | grep -vE "^$repo/k8s/(clusters|bootstrap)/" | sort)

while IFS= read -r project; do
  [[ -n $project ]] || continue
  awk -F'\t' -v p="$project" '$1 == p { print $2 "\t" $3 }' "$tmp/nested.tsv" >"$tmp/nested.$project"
  check_list "$tmp/nested.$project" "$project" "nested Applications"
done < <(cut -f1 "$tmp/nested.tsv" | sort -u)

while IFS= read -r key; do
  grep -qxF "$key" "$tmp/baseline.seen" || {
    echo "FAIL: stale baseline entry '${key//$'\t'/ / }' in scripts/argo-project-namespaces.baseline.tsv (gap fixed: remove it)" >&2
    errors=$((errors + 1))
  }
done <"$baseline_keys"

if ((errors > 0)); then
  echo "ERROR: $errors namespace(s) outside the destinations of their AppProject; add them to spec.destinations of the project (k8s/bootstrap/argocd-root/*-project.yaml)" >&2
  exit 1
fi
echo "OK: every rendered and nested-Application namespace is an allowed destination of its AppProject"
