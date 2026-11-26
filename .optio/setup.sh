#!/usr/bin/env bash
# PLT-535 : outils de controle du depot dans le pod d'agent Optio.
#
# Pourquoi : le 26/11, le pod d'agent n'avait ni shellcheck, ni helm, ni kubectl, ni
# module Python `yaml`, ni `jq` a la version du depot ; les controles du depot
# echouaient et une tache s'est bloquee. Optio 0.26.4 execute `.optio/setup.sh` a la
# preparation du pod d'agent (scripts/repo-init.sh de l'API : `cd /workspace/repo &&
# ./.optio/setup.sh`), avant tout agent.
#
# Ce que fait ce script : sans privilege, dans $HOME/.local/bin (deja en tete du PATH
# des execs de tache et de l'image agent), il installe les outils de `mise.toml` dont
# l'artefact est telechargeable depuis un hote deja autorise au pod, aux versions
# exactes de `mise.toml` et avec la somme de controle de `mise.lock` ; il installe
# aussi le module Python PyYAML epingle (6.0.2, meme epinglage que
# scripts/policy-check.sh).
#
# Ce qu'il ne fait pas : aucune regle reseau n'est touchee. Les hotes non autorises
# (get.helm.sh, dl.k8s.io, nodejs.org) restent inaccessibles : helm, kubectl et node
# sont signales ABSENT, pas installes. Aucun privilege n'est demande : tout se passe
# dans $HOME.
#
# Contrat de sortie : une ligne par outil (`SETUP_TOOL=OK ...` ou
# `SETUP_TOOL=ABSENT ...`), puis une ligne `SETUP_SUMMARY=...`, et un code de retour
# toujours nul. Une installation impossible est signalee, jamais fatale : le pod doit
# demarrer meme si un outil manque (repo-init.sh est en `set -e`).
#
# Variables d'environnement (utilisees par les tests) :
#   OPTIO_SETUP_BIN_DIR   repertoire d'installation (defaut : $HOME/.local/bin)
#   OPTIO_SETUP_DEADLINE  budget total en secondes (defaut : 240 ; la tache en impose 300)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
MISE_LOCK="$REPO_ROOT/mise.lock"

# PyYAML : meme version que scripts/policy-check.sh et .github/workflows/stateful-plan.yaml.
readonly PYYAML_PACKAGE="pyyaml"
readonly PYYAML_VERSION="6.0.2"

# Hotes deja autorises au pod d'agent (CiliumNetworkPolicy optio-agents,
# k8s/applications/platform/optio/networkpolicy.yaml). Cette liste ne sert qu'a
# decide : un outil dont l'artefact vient d'un autre hote est signale, pas installe.
readonly ALLOWED_HOSTS=(
  github.com
  objects.githubusercontent.com
  pypi.org
  files.pythonhosted.org
  registry.npmjs.org
)

BIN_DIR="${OPTIO_SETUP_BIN_DIR:-$HOME/.local/bin}"
PREFIX_DIR="$(dirname -- "$BIN_DIR")"
DEADLINE_SECONDS="${OPTIO_SETUP_DEADLINE:-240}"
DOWNLOAD_TIMEOUT_SECONDS="${OPTIO_SETUP_DOWNLOAD_TIMEOUT:-120}"

STARTED_AT="$(date +%s)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/optio-setup.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/optio-setup.$$")"
mkdir -p "$TMP_ROOT" 2>/dev/null || true
trap 'rm -rf "$TMP_ROOT"' EXIT

# Outils de `mise.toml`, dans l'ordre d'importance pour les controles du depot :
# le module yaml (qui depend de python) passe avant les outils secondaires.
# Format : nom|binaire installe|genre d'installation (binary, tar, prefix).
readonly TOOL_RECIPES=(
  'jq|jq|binary'
  'yq|yq|binary'
  'just|just|tar'
  'kustomize|kustomize|tar'
  'shellcheck|shellcheck|tar'
  'python|python3|prefix'
  'kubeconform|kubeconform|tar'
  'ripgrep|rg|tar'
  'prek|prek|tar'
  'vale|vale|tar'
  'kyverno|kyverno|tar'
  'helm|helm|tar'
  'kubectl|kubectl|binary'
  'node|node|tar'
)

log() { printf '%s\n' "$*"; }

report_ok() { # outil version etat
  printf 'SETUP_TOOL=OK tool=%s version=%s state=%s\n' "$1" "$2" "$3"
}

report_absent() { # outil version raison [detail]
  printf 'SETUP_TOOL=ABSENT tool=%s version=%s reason=%s' "$1" "$2" "$3"
  if [ -n "${4:-}" ]; then printf ' %s' "$4"; fi
  printf '\n'
}

remaining_seconds() {
  echo $((DEADLINE_SECONDS - ($(date +%s) - STARTED_AT)))
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

url_host() {
  local host
  host="${1#*://}"
  host="${host%%/*}"
  printf '%s' "${host%%:*}"
}

host_allowed() {
  local candidate=$1 allowed
  for allowed in "${ALLOWED_HOSTS[@]}"; do
    [ "$candidate" = "$allowed" ] && return 0
  done
  return 1
}

# Commande qui affiche la version d'un outil. Chaque outil a la sienne : yq et
# ShellCheck ont une premiere ligne de presentation, kubectl annonce aussi la
# version de kustomize embarquee.
version_command() {
  case "$1" in
    kubeconform) printf '%s' '-v' ;;
    kustomize | kyverno) printf '%s' 'version' ;;
    kubectl) printf '%s' 'version --client' ;;
    helm) printf '%s' 'version --short' ;;
    *) printf '%s' '--version' ;;
  esac
}

# Version trouvee : premiere version semantique annoncee par l'outil.
detect_version() { # outil binaire
  local tool=$1 binary=$2 out
  local -a command=()
  [ -x "$binary" ] || return 0
  read -r -a command <<<"$(version_command "$tool")"
  out="$("$binary" "${command[@]}" 2>&1 || true)"
  printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# Decompression d'une archive tar (gz, xz ou sans compression). Sans binaire xz,
# GNU tar ne lit pas un .tar.xz : le module lzma de python prend le relais.
extract_tar() {
  local archive=$1 dest=$2 plain
  tar -xf "$archive" -C "$dest" 2>/dev/null && return 0
  case "$archive" in
    *.xz)
      plain="$archive.tar"
      python3 -c 'import lzma,shutil,sys
with lzma.open(sys.argv[1],"rb") as src, open(sys.argv[2],"wb") as dst:
    shutil.copyfileobj(src,dst)' "$archive" "$plain" 2>/dev/null || return 1
      tar -xf "$plain" -C "$dest" 2>/dev/null || return 1
      rm -f "$plain"
      return 0
      ;;
  esac
  return 1
}

# Lit mise.lock pour la plateforme courante : une ligne par outil
# `outil<TAB>version<TAB>url<TAB>sha256` (url et sha vides si la plateforme
# n'est pas lockee).
read_mise_lock() {
  local platform=$1
  [ -r "$MISE_LOCK" ] || return 1
  awk -v plat="$platform" '
    /^\[\[tools\.[A-Za-z0-9._-]+\]\]$/ {
      name = $0
      sub(/^\[\[tools\./, "", name)
      sub(/\]\]$/, "", name)
      current = name
      order[++count] = name
      next
    }
    /^version = "/ {
      value = $0
      sub(/^version = "/, "", value)
      sub(/"$/, "", value)
      version[current] = value
      next
    }
    /^\[tools\..*"platforms\.[^"]+"\]$/ {
      section = $0
      platform_name = section
      sub(/^.*"platforms\./, "", platform_name)
      sub(/"\].*$/, "", platform_name)
      in_platform = (platform_name == plat) ? 1 : 0
      next
    }
    in_platform && /^checksum = "/ {
      value = $0
      sub(/^checksum = "/, "", value)
      sub(/"$/, "", value)
      sub(/^sha256:/, "", value)
      checksum[current] = value
      next
    }
    in_platform && /^url = "/ {
      value = $0
      sub(/^url = "/, "", value)
      sub(/"$/, "", value)
      url[current] = value
      next
    }
    END {
      for (position = 1; position <= count; position++) {
        tool = order[position]
        printf "%s\t%s\t%s\t%s\n", tool, version[tool], ((tool in url) ? url[tool] : ""), ((tool in checksum) ? checksum[tool] : "")
      }
    }
  ' "$MISE_LOCK"
}

# Un outil est-il deja a la bonne version ? Le repertoire d'installation d'abord
# (c'est lui qui gagne dans le PATH), puis le binaire deja dans le PATH.
already_installed() { # binaire version
  local binary=$1 version=$2 found
  if [ -x "$BIN_DIR/$binary" ] && [ "$(detect_version "$binary" "$BIN_DIR/$binary")" = "$version" ]; then
    printf '%s' "$BIN_DIR/$binary"
    return 0
  fi
  found="$(command -v "$binary" 2>/dev/null || true)"
  if [ -n "$found" ] && [ "$(detect_version "$binary" "$found")" = "$version" ]; then
    printf '%s' "$found"
    return 0
  fi
  return 1
}

# Pose un binaire dans le repertoire d'installation. Le fichier est ecrit a cote
# puis renomme : un binaire deja en cours d'execution ne peut pas etre ecrase
# ("Text file busy"), un renommage si.
install_binary() { # source destination
  local source=$1 destination=$2 staging="$2.new"
  cp "$source" "$staging" && chmod 0755 "$staging" && mv -f "$staging" "$destination"
}

# Installe un outil. Rend 0 si l'outil est a la version voulue, 1 s'il reste absent.
install_tool() { # outil binaire genre version url sha256
  local tool=$1 binary=$2 kind=$3 version=$4 url=$5 sha=$6
  local host timeout archive extracted source installed

  if already_installed "$binary" "$version" >/dev/null; then
    report_ok "$tool" "$version" already_present
    return 0
  fi

  if [ -z "$url" ] || [ -z "$sha" ]; then
    report_absent "$tool" "$version" platform_not_locked
    return 1
  fi

  host="$(url_host "$url")"
  if ! host_allowed "$host"; then
    report_absent "$tool" "$version" host_not_allowed "host=$host"
    return 1
  fi

  if [ "$(remaining_seconds)" -le 5 ]; then
    report_absent "$tool" "$version" deadline_exceeded
    return 1
  fi

  timeout="$DOWNLOAD_TIMEOUT_SECONDS"
  if [ "$(remaining_seconds)" -lt "$timeout" ]; then
    timeout="$(remaining_seconds)"
  fi

  archive="$TMP_ROOT/$tool.download"
  if ! curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time "$timeout" \
    -o "$archive" "$url" 2>"$TMP_ROOT/$tool.curl.log"; then
    report_absent "$tool" "$version" download_failed "host=$(url_host "$url")"
    return 1
  fi

  if [ "$(sha256_of "$archive")" != "$sha" ]; then
    rm -f "$archive"
    report_absent "$tool" "$version" checksum_mismatch
    return 1
  fi

  case "$kind" in
    binary)
      if ! install_binary "$archive" "$BIN_DIR/$binary"; then
        rm -f "$archive"
        report_absent "$tool" "$version" install_failed
        return 1
      fi
      ;;
    tar)
      extracted="$TMP_ROOT/$tool.extract"
      mkdir -p "$extracted"
      if ! extract_tar "$archive" "$extracted"; then
        rm -f "$archive"
        report_absent "$tool" "$version" install_failed
        return 1
      fi
      source="$(find "$extracted" -type f -name "$binary" -perm -u+x 2>/dev/null | head -1)"
      if [ -z "$source" ] || ! install_binary "$source" "$BIN_DIR/$binary"; then
        rm -f "$archive"
        report_absent "$tool" "$version" install_failed
        return 1
      fi
      ;;
    prefix)
      # Archive « install_only » : le repertoire de premier niveau (python/) est
      # deploye dans le prefixe, les binaires sont lies dans le repertoire d'installation.
      if ! extract_tar "$archive" "$PREFIX_DIR" || [ ! -x "$PREFIX_DIR/python/bin/python3" ]; then
        rm -f "$archive"
        report_absent "$tool" "$version" install_failed
        return 1
      fi
      ln -sfn ../python/bin/python3 "$BIN_DIR/$binary"
      if [ -x "$PREFIX_DIR/python/bin/python3.12" ]; then
        ln -sfn ../python/bin/python3.12 "$BIN_DIR/python3.12"
      fi
      ;;
    *)
      rm -f "$archive"
      report_absent "$tool" "$version" unknown_archive_kind
      return 1
      ;;
  esac
  rm -f "$archive"

  installed="$(detect_version "$tool" "$BIN_DIR/$binary")"
  if [ "$installed" != "$version" ]; then
    report_absent "$tool" "$version" version_mismatch "found=${installed:-none}"
    return 1
  fi
  report_ok "$tool" "$version" installed
  return 0
}

# PyYAML : installe dans le python epingle (son site-packages), pas dans le site
# utilisateur : les controles du depot lisent le module avec `python3 -I`, mode
# isole qui ignore le site utilisateur.
install_pyyaml() {
  local python="$BIN_DIR/python3" found log_file

  found="$("$python" -I -c 'import yaml; print(yaml.__version__)' 2>/dev/null || true)"
  if [ "$found" = "$PYYAML_VERSION" ]; then
    report_ok "$PYYAML_PACKAGE" "$PYYAML_VERSION" already_present
    return 0
  fi
  if [ ! -x "$python" ]; then
    report_absent "$PYYAML_PACKAGE" "$PYYAML_VERSION" python_unavailable
    return 1
  fi
  if [ "$(remaining_seconds)" -le 10 ]; then
    report_absent "$PYYAML_PACKAGE" "$PYYAML_VERSION" deadline_exceeded
    return 1
  fi

  log_file="$TMP_ROOT/pyyaml.pip.log"
  if ! "$python" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
    --only-binary=:all: "$PYYAML_PACKAGE==$PYYAML_VERSION" >"$log_file" 2>&1; then
    # Pas de roue pour cette plateforme : on tente la source, qui construit le
    # module en Python pur quand le compilateur manque.
    if ! "$python" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
      "$PYYAML_PACKAGE==$PYYAML_VERSION" >>"$log_file" 2>&1; then
      report_absent "$PYYAML_PACKAGE" "$PYYAML_VERSION" install_failed
      return 1
    fi
  fi

  found="$("$python" -I -c 'import yaml; print(yaml.__version__)' 2>/dev/null || true)"
  if [ "$found" != "$PYYAML_VERSION" ]; then
    report_absent "$PYYAML_PACKAGE" "$PYYAML_VERSION" version_mismatch "found=${found:-none}"
    return 1
  fi
  report_ok "$PYYAML_PACKAGE" "$PYYAML_VERSION" installed
  return 0
}

main() {
  local platform tool binary kind version url sha entry lock_output found
  local installed=0 absent=0
  local -a lock_entries=()
  declare -A LOCK_VERSION=() LOCK_URL=() LOCK_SHA=()

  case "$(uname -m)" in
    x86_64) platform="linux-x64" ;;
    aarch64 | arm64) platform="linux-arm64" ;;
    *)
      log "SETUP_SUMMARY=BLOCKED reason=unsupported_arch arch=$(uname -m)"
      exit 0
      ;;
  esac

  mkdir -p "$BIN_DIR" 2>/dev/null || true

  lock_output="$(read_mise_lock "$platform")" || lock_output=""
  if [ -z "$lock_output" ]; then
    for entry in "${TOOL_RECIPES[@]}"; do
      tool="${entry%%|*}"
      report_absent "$tool" unknown lock_unreadable
      absent=$((absent + 1))
    done
    report_absent "$PYYAML_PACKAGE" "$PYYAML_VERSION" lock_unreadable
    absent=$((absent + 1))
    log "SETUP_SUMMARY=BLOCKED reason=lock_unreadable file=$MISE_LOCK absent=$absent"
    exit 0
  fi
  mapfile -t lock_entries <<<"$lock_output"
  for entry in "${lock_entries[@]}"; do
    tool="${entry%%$'\t'*}"
    version="$(printf '%s' "$entry" | cut -f2)"
    url="$(printf '%s' "$entry" | cut -f3)"
    sha="$(printf '%s' "$entry" | cut -f4)"
    LOCK_VERSION["$tool"]="$version"
    LOCK_URL["$tool"]="$url"
    LOCK_SHA["$tool"]="$sha"
  done

  for entry in "${TOOL_RECIPES[@]}"; do
    IFS='|' read -r tool binary kind <<<"$entry"
    version="${LOCK_VERSION[$tool]:-}"
    if [ -z "$version" ]; then
      report_absent "$tool" unknown not_in_mise_lock
      absent=$((absent + 1))
      continue
    fi
    if install_tool "$tool" "$binary" "$kind" "$version" "${LOCK_URL[$tool]}" "${LOCK_SHA[$tool]}"; then
      installed=$((installed + 1))
    else
      absent=$((absent + 1))
    fi
  done

  if install_pyyaml; then
    installed=$((installed + 1))
  else
    absent=$((absent + 1))
  fi

  log "SETUP_SUMMARY=DONE tools=$((installed + absent)) installed=$installed absent=$absent duration_seconds=$(($(date +%s) - STARTED_AT)) deadline_seconds=$DEADLINE_SECONDS"
  exit 0
}

main "$@"
