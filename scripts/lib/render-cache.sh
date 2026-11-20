#!/usr/bin/env bash
# Cache de rendu `kustomize build --enable-helm` partage par v1-contract, backup-contract,
# policy-check et les tests qui rendent les memes racines.
#
#   source scripts/lib/render-cache.sh
#   f="$(render_root k8s/applications/media)"   # chemin d'un fichier YAML rendu (a ne pas modifier)
#
#   scripts/lib/render-cache.sh render <racine>        meme chose en sous-processus (affiche le chemin)
#   scripts/lib/render-cache.sh prerender <racine>...  rend les racines en parallele (RENDER_JOBS, defaut 6)
#   scripts/lib/render-cache.sh key [racine]           affiche la cle (diagnostic)
#
# Correction (jamais de rendu perime) : la cle d'une racine est le sha256 de
#   - le contenu de TOUS les fichiers de k8s/ (suivis + non suivis non ignores, etat de l'arbre de
#     travail, donc modifications non commitees incluses) : chemin + hash de contenu ;
#   - le nom de la racine et les versions de kustomize et helm.
# Toute modification dans k8s/ invalide donc toutes les racines (choix volontaire : plus sur que
# de suivre les bases locales). Les fichiers ignores (charts/ telecharges par helm) ne sont pas
# dans la cle : la version du chart est dans le kustomization.yaml suivi, et sans cache kustomize
# reutiliserait de la meme facon le chart deja present sur le disque. En cas de doute (git
# indisponible, hash impossible) : pas de cache, rendu direct. Un echec de rendu n'est jamais mis en cache.
#
# Concurrence : `--enable-helm` ecrit <racine>/charts/. Un verrou par groupe de racines
# (3 premiers composants du chemin, donc k8s/infrastructure/storage et k8s/infrastructure/storage/longhorn
# partagent le meme verrou) garantit qu'un seul rendu a la fois touche un meme charts/.
# Racine du depot : RENDER_CACHE_REPO (defaut : git toplevel du repertoire courant).
# Dossier du cache : RENDER_CACHE_DIR (defaut ${XDG_CACHE_HOME:-~/.cache}/kube-ops/render).
# Entrees non relues depuis plus de RENDER_CACHE_TTL_DAYS (defaut 3) jours supprimees.

_rc_dir() { printf '%s\n' "${RENDER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kube-ops/render}"; }

# Cle de l'arbre k8s/ (calculee une fois par processus).
_rc_tree_key() {
  if [[ -n "${_RC_TREE_KEY:-}" ]]; then printf '%s\n' "$_RC_TREE_KEY"; return 0; fi
  local repo list key
  repo="${RENDER_CACHE_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}" || return 1
  [[ -n $repo && -d $repo/k8s ]] || return 1
  list="$(mktemp "${TMPDIR:-/tmp}/render-cache-list.XXXXXX")" || return 1
  # fichiers presents (suivis ou non suivis non ignores), moins les suivis supprimes
  if ! (cd "$repo" && {
    git ls-files -z -co --exclude-standard -- k8s | tr '\0' '\n' | LC_ALL=C sort -u >"$list.all"
    git ls-files -d -- k8s | LC_ALL=C sort -u >"$list.del"
    LC_ALL=C comm -23 "$list.all" "$list.del" >"$list"
    # un lien symbolique casse ferait echouer hash-object : on le signale en echec (pas de cache)
    git hash-object --stdin-paths <"$list" >"$list.sum"
    paste -d' ' "$list" "$list.sum" | shasum -a 256
  } >"$list.key" 2>/dev/null); then
    rm -f "$list" "$list.all" "$list.del" "$list.sum" "$list.key"
    return 1
  fi
  key="$(cut -d' ' -f1 <"$list.key")"
  rm -f "$list" "$list.all" "$list.del" "$list.sum" "$list.key"
  [[ -n $key ]] || return 1
  local tools
  tools="$( (kustomize version 2>/dev/null; helm version --short 2>/dev/null) | tr '\n' ' ')"
  _RC_TREE_KEY="$(printf '%s %s' "$key" "$tools" | shasum -a 256 | cut -d' ' -f1)"
  printf '%s\n' "$_RC_TREE_KEY"
}

_rc_root_key() { # <racine normalisee>
  local tk
  tk="$(_rc_tree_key)" || return 1
  printf '%s %s' "$tk" "$1" | shasum -a 256 | cut -d' ' -f1
}

_rc_norm() { local r="$1"; r="${r#./}"; r="${r%/}"; printf '%s\n' "$r"; }

_rc_lock() { # <fichier verrou> ; attente max ~15 min, verrou orphelin repris
  local lock="$1" waited=0 pid
  until mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
    sleep 0.3
    waited=$((waited + 1))
    ((waited < 3000)) || { echo "render-cache: verrou bloque $lock" >&2; return 1; }
  done
  printf '%s' "$$" >"$lock/pid"
}

render_root() { # <racine> -> chemin du YAML rendu sur stdout ; code != 0 si le rendu echoue
  local root dir key out tmp lock group
  root="$(_rc_norm "${1:?racine manquante}")"
  [[ -f "$root/kustomization.yaml" || -f "$root/kustomization.yml" ]] || {
    echo "render-cache: pas de kustomization dans $root" >&2
    return 1
  }
  dir="$(_rc_dir)"
  mkdir -p "$dir"
  if key="$(_rc_root_key "$root")"; then
    out="$dir/$key.yaml"
    if [[ -e $out ]]; then touch "$out" 2>/dev/null || true; printf '%s\n' "$out"; return 0; fi
  else
    key=""
    out="$(mktemp "$dir/nocache.XXXXXX")" # pas de cache fiable : fichier jetable (purge par TTL)
  fi
  group="$(printf '%s' "$root" | cut -d/ -f1-3 | tr '/' '_')"
  lock="$dir/.lock.$group"
  _rc_lock "$lock" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" RETURN
  if [[ -n $key && -e $out ]]; then printf '%s\n' "$out"; return 0; fi # rendu par un concurrent
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  if ! kustomize build --enable-helm "$root" >"$tmp" 2>"$tmp.err"; then
    echo "render-cache: kustomize build --enable-helm $root a echoue :" >&2
    cat "$tmp.err" >&2
    rm -f "$tmp" "$tmp.err"
    return 1
  fi
  [[ -s $tmp.err ]] && cat "$tmp.err" >&2
  rm -f "$tmp.err"
  mv -f "$tmp" "$out"
  printf '%s\n' "$out"
}

render_cache_prune() {
  local dir
  dir="$(_rc_dir)"
  [[ -d $dir ]] || return 0
  find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name 'nocache.*' \) -mtime +"${RENDER_CACHE_TTL_DAYS:-3}" -delete 2>/dev/null || true
  find "$dir" -maxdepth 1 -name '.tmp.*' -mtime +1 -delete 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    render) render_root "$1" ;;
    key) _rc_root_key "$(_rc_norm "${1:-.}")" ;;
    prerender)
      render_cache_prune
      ((${#} > 0)) || exit 0
      printf '%s\0' "$@" | xargs -0 -n1 -P "${RENDER_JOBS:-6}" -I{} bash "$self" render {} >/dev/null
      ;;
    *) echo "usage: $0 render <racine> | prerender <racine>... | key [racine]" >&2; exit 2 ;;
  esac
fi
