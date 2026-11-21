#!/usr/bin/env bash
# Controle des descripteurs `argocd-app.yaml` (PLT-394, ApplicationSet `apps`).
# Contrat : docs/operations/argo-app-descriptor.md.
#
#   a. schema de chaque k8s/applications/<domaine>/<app>/argocd-app.yaml : champs connus et types,
#      `name` DNS-1123 unique et egal au dossier, `project` defini dans k8s/bootstrap/argocd-root,
#      `namespace` present dans le rendu de l'app, tous les namespaces rendus admis par le projet ;
#      descripteur jamais liste dans une kustomization ni hors k8s/applications/*/* ;
#   b. chaque `extraPaths` existe (chemin depuis la racine du depot, sans `..` ni joker) ;
#   c. un domaine migre est COMPLET (chaque sous-dossier avec kustomization.yaml a son descripteur)
#      et l'union des rendus `kustomize build --enable-helm` des apps == rendu du domaine, objets
#      compares par (kind, namespace, name) et contenu normalise (cles triees) ;
#   d. aucune app n'est generee a la fois par `apps` et par l'ApplicationSet `applications` ;
#      `preview: true` (opt-in aux previews PLT-394/395) : l'app ne rend que des kinds admis par la liste
#      blanche de l'AppProject `previews` (hors Namespace, ScaledObject, InterceptorRoute, retires par
#      l'ApplicationSet previews) ;
#   e. le projet `apps` refuse (`!ns`) chaque namespace d'infrastructure du projet infrastructure
#      qui n'est pas un namespace d'application.
#
# Usage : bash scripts/check-argo-app-descriptors.sh [racine-du-depot]   (defaut : depot courant)
# Lecture seule : aucun secret, aucun acces cluster.
set -euo pipefail

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 2; }
command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize is required" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/argo-project-dest.sh
source "$here/lib/argo-project-dest.sh"
repo="$(cd "${1:-$here/..}" && pwd)"
root_dir="$repo/k8s/bootstrap/argocd-root"
apps_dir="$repo/k8s/applications"
[[ -d $root_dir ]] || { echo "ERROR: $root_dir not found" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

dns1123='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
allowed_keys='name namespace project postMerge preview extraPaths'

render() { # <dir relatif> -> YAML rendu sur stdout
  local rel="$1"
  if [[ -f $repo/scripts/lib/render-cache.sh && -e $repo/.git ]]; then
    (cd "$repo" && source scripts/lib/render-cache.sh && cat "$(render_root "$rel")")
  else
    kustomize build --enable-helm "$repo/$rel"
  fi
}

# objets rendus : "kind|namespace|name<TAB>json normalise" (un par ligne, trie)
objects() {
  yq eval --no-doc '
    select(.kind != null and .kind != "List") |
    ([.kind, (.metadata.namespace // ""), .metadata.name] | join("|")) + "	" + (sort_keys(..) | to_json(0))
  ' | LC_ALL=C sort
}

# namespaces rendus : kind Namespace = metadata.name, autres objets = metadata.namespace
namespaces() {
  yq eval --no-doc '
    select(.kind != null and .kind != "List") |
    (select(.kind == "Namespace") | .metadata.name),
    (select(.kind != "Namespace" and .metadata.namespace != null) | .metadata.namespace)
  ' | LC_ALL=C sort -u
}

# --- AppProjects du root : <projet> -> destinations ---------------------------------------------
mkdir -p "$tmp/proj"
for f in "$root_dir"/*.yaml; do
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    yq eval --no-doc "select(.kind == \"AppProject\" and .metadata.name == \"$name\") | .spec.destinations[] | .namespace // \"\"" "$f" >"$tmp/proj/$name"
  done < <(yq eval --no-doc 'select(.kind == "AppProject") | .metadata.name' "$f")
done

# --- e. le projet `apps` refuse les namespaces d'infrastructure ---------------------------------
apps_appset="$root_dir/apps-applicationset.yaml"
if [[ -f $apps_appset || -f $tmp/proj/apps ]]; then
  [[ -f $apps_appset ]] || fail "k8s/bootstrap/argocd-root/apps-applicationset.yaml missing (AppProject apps exists)"
  if [[ ! -f $tmp/proj/apps ]]; then
    fail "AppProject apps is not defined in k8s/bootstrap/argocd-root"
  else
    grep -qxF '*' "$tmp/proj/apps" || fail "AppProject apps must allow namespace '*' (negations apply on top of it)"
    if [[ -f $tmp/proj/infrastructure && -f $tmp/proj/applications ]]; then
      # a refuser = namespaces du projet infrastructure absents du projet applications, plus ceux que
      # applications admettait par erreur alors qu'ils sont a l'infrastructure.
      always_infra='argocd arc-runners arc-runners-website arc-runners-kube-ops'
      while IFS= read -r ns; do
        [[ -n $ns && $ns != *'*'* && $ns != '!'* ]] || continue
        grep -qxF "$ns" "$tmp/proj/applications" && ! grep -qwF -- "$ns" <<<"$always_infra" && continue
        argo_ns_allowed "$tmp/proj/apps" "$ns" && fail "namespace d'infrastructure '$ns' is allowed by AppProject apps: add '!$ns' to apps-project.yaml"
      done <"$tmp/proj/infrastructure"
    fi
    for ns in argocd kube-system; do
      argo_ns_allowed "$tmp/proj/apps" "$ns" && fail "AppProject apps must deny namespace '$ns'"
    done
  fi
fi

# --- descripteurs -------------------------------------------------------------------------------
: >"$tmp/descriptors"
while IFS= read -r f; do
  [[ -n $f ]] && printf '%s\n' "$f" >>"$tmp/descriptors"
done < <(find "$apps_dir" -mindepth 3 -maxdepth 3 -name argocd-app.yaml 2>/dev/null | LC_ALL=C sort)

# hors k8s/applications/<domaine>/<app>/ : jamais lu par le generateur, donc piege silencieux
while IFS= read -r f; do
  rel="${f#"$repo"/}"
  grep -qxF "$f" "$tmp/descriptors" || fail "$rel: argocd-app.yaml must be exactly k8s/applications/<domaine>/<app>/argocd-app.yaml"
done < <(find "$repo/k8s" -name argocd-app.yaml 2>/dev/null | LC_ALL=C sort)
# jamais dans une kustomization (ce n'est pas un manifeste Kubernetes)
while IFS= read -r k; do
  fail "${k#"$repo"/}: argocd-app.yaml must not be listed in a kustomization"
done < <(grep -rlE 'argocd-app\.yaml' "$repo/k8s" --include='kustomization.yaml' --include='kustomization.yml' 2>/dev/null || true)

: >"$tmp/names"
: >"$tmp/domains"
while IFS= read -r f; do
  [[ -n $f ]] || continue
  dir="$(dirname "$f")"; rel="${dir#"$repo"/}"; app="$(basename "$dir")"; domain="$(basename "$(dirname "$dir")")"
  echo "$domain" >>"$tmp/domains"
  d="$rel/argocd-app.yaml"

  if ! yq eval '.' "$f" >/dev/null 2>&1; then fail "$d: invalid YAML"; continue; fi
  [[ "$(yq eval 'tag' "$f")" == '!!map' ]] || { fail "$d: must be a YAML mapping"; continue; }

  # a. champs connus
  while IFS= read -r key; do
    grep -qwF -- "$key" <<<"$allowed_keys" || fail "$d: unknown field '$key' (allowed: $allowed_keys)"
  done < <(yq eval 'keys | .[]' "$f")

  name="$(yq eval '.name // ""' "$f")"
  [[ "$(yq eval '.name | tag' "$f")" == '!!str' ]] || fail "$d: name must be a string"
  if [[ ! $name =~ $dns1123 || ${#name} -gt 59 ]]; then fail "$d: name '$name' is not DNS-1123 (max 59 characters)"; fi
  [[ $name == "$app" ]] || fail "$d: name '$name' must equal the app directory '$app'"
  if grep -qxF "$name" "$tmp/names"; then fail "$d: duplicate name '$name' (Application app-$name already generated by another descriptor)"; fi
  echo "$name" >>"$tmp/names"

  ns="$(yq eval '.namespace // ""' "$f")"
  [[ "$(yq eval '.namespace | tag' "$f")" == '!!str' ]] || fail "$d: namespace is required and must be a string"
  if [[ ! $ns =~ $dns1123 || ${#ns} -gt 63 ]]; then fail "$d: namespace '$ns' is not DNS-1123"; fi

  project="$(yq eval '.project // "apps"' "$f")"
  if [[ "$(yq eval 'has("project")' "$f")" == true ]]; then
    [[ "$(yq eval '.project | tag' "$f")" == '!!str' ]] || fail "$d: project must be a string"
  fi
  if [[ ! -f $tmp/proj/$project || $project == default ]]; then fail "$d: project '$project' is not an AppProject of k8s/bootstrap/argocd-root (or is 'default')"; fi

  if [[ "$(yq eval 'has("postMerge")' "$f")" == true ]]; then
    pm="$(yq eval '.postMerge' "$f")"
    [[ $pm == revert || $pm == notify ]] || fail "$d: postMerge must be 'revert' or 'notify' (got '$pm')"
  fi
  if [[ "$(yq eval 'has("preview")' "$f")" == true ]]; then
    [[ "$(yq eval '.preview | tag' "$f")" == '!!bool' ]] || fail "$d: preview must be true or false"
  fi

  # b. extraPaths
  if [[ "$(yq eval 'has("extraPaths")' "$f")" == true ]]; then
    if [[ "$(yq eval '.extraPaths | tag' "$f")" != '!!seq' ]]; then
      fail "$d: extraPaths must be a list"
    else
      while IFS= read -r p; do
        [[ -n $p ]] || { fail "$d: extraPaths contains an empty entry"; continue; }
        if [[ $p == /* || $p == *..* || $p == *'*'* || $p == *'?'* || $p == *';'* ]]; then
          fail "$d: extraPaths entry '$p' must be a plain path from the repository root (no leading /, .., glob or ;)"
        elif [[ ! -e $repo/$p ]]; then
          fail "$d: extraPaths entry '$p' does not exist"
        fi
      done < <(yq eval '.extraPaths[] | tostring' "$f")
    fi
  fi

  # rendu de l'app : namespace declare present, tous les namespaces admis par le projet
  if [[ -f $dir/kustomization.yaml ]]; then
    if render "$rel" >"$tmp/app.rendered" 2>"$tmp/render.err"; then
      namespaces <"$tmp/app.rendered" >"$tmp/app.ns"
      grep -qxF "$ns" "$tmp/app.ns" || fail "$d: namespace '$ns' is not among the namespaces rendered by $rel ($(paste -sd, "$tmp/app.ns"))"
      if [[ -f $tmp/proj/$project ]]; then
        while IFS= read -r rns; do
          [[ -n $rns ]] || continue
          argo_ns_allowed "$tmp/proj/$project" "$rns" || fail "$d: rendered namespace '$rns' is not a destination of AppProject '$project'"
        done <"$tmp/app.ns"
      fi
      objects <"$tmp/app.rendered" >"$tmp/app.objects.$app"
      if [[ "$(yq eval '.preview // false' "$f")" == true ]]; then
        if [[ ! -f $tmp/preview.whitelist ]]; then
          for pf in "$root_dir"/*.yaml; do
            yq eval --no-doc 'select(.kind == "AppProject" and .metadata.name == "previews") | .spec.namespaceResourceWhitelist[] | .group + "/" + .kind' "$pf"
          done >"$tmp/preview.whitelist"
        fi
        if [[ ! -s $tmp/preview.whitelist ]]; then
          fail "$d: preview is true but AppProject previews has no namespaceResourceWhitelist in k8s/bootstrap/argocd-root"
        else
          while IFS= read -r gk; do
            [[ -n $gk ]] || continue
            case "$gk" in */Namespace | keda.sh/ScaledObject | http.keda.sh/InterceptorRoute) continue ;; esac
            grep -qxF "$gk" "$tmp/preview.whitelist" || fail "$d: preview is true but $rel renders $gk, which AppProject previews does not admit (set preview: false or remove the object)"
          done < <(yq eval --no-doc 'select(.kind != null and .kind != "List") | ((.apiVersion | select(contains("/")) | sub("/.*", "")) // "") + "/" + .kind' "$tmp/app.rendered" | LC_ALL=C sort -u)
        fi
      fi
    else
      fail "$d: kustomize build failed for $rel: $(head -3 "$tmp/render.err" | tr '\n' ' ')"
    fi
  else
    fail "$d: $rel has no kustomization.yaml"
  fi
done <"$tmp/descriptors"

# --- c + d. domaines migres ---------------------------------------------------------------------
gen_paths="$tmp/appset-paths"
: >"$gen_paths"
[[ -f $root_dir/applications-applicationset.yaml ]] \
  && yq eval '.spec.generators[].git.directories[] | select(.exclude != true) | .path' "$root_dir/applications-applicationset.yaml" >"$gen_paths"

while IFS= read -r domain; do
  [[ -n $domain ]] || continue
  drel="k8s/applications/$domain"

  # d. plus generee par `applications`
  while IFS= read -r g; do
    [[ -n $g ]] || continue
    while IFS= read -r f; do
      dir="${f%/argocd-app.yaml}"; rel="${dir#"$repo"/}"
      [[ $rel == "$drel"/* ]] || continue
      if [[ $rel == "$g" || $rel == "$g"/* ]]; then
        fail "$rel is generated by both ApplicationSet apps and ApplicationSet applications (generator path '$g'): remove '$g' from applications-applicationset.yaml in the same PR"
      elif [[ $g == "$rel"/* ]]; then
        fail "$rel is generated by apps while ApplicationSet applications still generates '$g' (descendant)"
      fi
    done <"$tmp/descriptors"
  done <"$gen_paths"

  [[ -f $apps_dir/$domain/kustomization.yaml ]] || { fail "$drel has no kustomization.yaml: cannot prove render equivalence"; continue; }

  # c. complet : chaque sous-dossier avec kustomization.yaml a son descripteur
  for sub in "$apps_dir/$domain"/*/; do
    [[ -f ${sub}kustomization.yaml ]] || continue
    [[ -f ${sub}argocd-app.yaml ]] || fail "$drel is partially migrated: ${sub#"$repo"/} has no argocd-app.yaml (a domain migrates whole, otherwise the domain Application prunes the apps it no longer generates)"
  done

  # c. equivalence de rendu : domaine == union des apps
  if ! render "$drel" >"$tmp/domain.rendered" 2>"$tmp/render.err"; then
    fail "kustomize build failed for $drel: $(head -3 "$tmp/render.err" | tr '\n' ' ')"
    continue
  fi
  objects <"$tmp/domain.rendered" >"$tmp/domain.objects"
  : >"$tmp/union.objects"
  : >"$tmp/union.keys"
  for f in "$apps_dir/$domain"/*/argocd-app.yaml; do
    [[ -f $f ]] || continue
    app="$(basename "$(dirname "$f")")"
    [[ -f $tmp/app.objects.$app ]] || continue
    while IFS=$'\t' read -r key json; do
      if grep -qxF "$key" "$tmp/union.keys"; then
        fail "$drel: object $key is rendered by more than one app (shared resource: move it to a single app)"
      fi
      echo "$key" >>"$tmp/union.keys"
      printf '%s\t%s\n' "$key" "$json" >>"$tmp/union.objects"
    done <"$tmp/app.objects.$app"
  done
  LC_ALL=C sort -o "$tmp/union.objects" "$tmp/union.objects"
  cut -f1 "$tmp/domain.objects" >"$tmp/domain.keys"
  while IFS= read -r key; do
    grep -qxF "$key" "$tmp/union.keys" || fail "$drel: object $key is rendered by the domain but by no app (domain-level file or transformation lost: it would be pruned)"
  done <"$tmp/domain.keys"
  while IFS= read -r key; do
    grep -qxF "$key" "$tmp/domain.keys" || fail "$drel: object $key is rendered by an app but not by the domain"
  done <"$tmp/union.keys"
  while IFS=$'\t' read -r key json; do
    other="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$tmp/union.objects")"
    [[ -z $other || $other == "$json" ]] || fail "$drel: object $key differs between the domain render and the app render (domain-level transformation such as patch, labels or namespace not reproduced per app)"
  done <"$tmp/domain.objects"
done < <(LC_ALL=C sort -u "$tmp/domains")

if ((errors > 0)); then
  echo "ERROR: $errors problem(s) with argocd-app.yaml descriptors (contract: docs/operations/argo-app-descriptor.md)" >&2
  exit 1
fi
n="$(grep -c . "$tmp/descriptors" || true)"
echo "OK: argocd-app.yaml contract ($n descriptor(s); AppProject apps denies infrastructure namespaces)"
