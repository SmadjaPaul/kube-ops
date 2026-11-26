#!/usr/bin/env bash
# PLT-535 : controle prealable des outils de controle du depot (pod d'agent Optio).
#
# Pourquoi : le 26/11, le pod d'agent n'avait ni shellcheck, ni helm, ni kubectl, ni
# module Python `yaml`, ni `jq` a la version du depot ; les controles du depot
# echouaient et une tache s'est bloquee. `.optio/setup.sh` installe ces outils a la
# preparation du pod ; ce script dit ce que le pod peut faire, avant qu'un agent ne
# lance un controle qui echouera.
#
# Ce qu'il fait : il lit le contrat d'outils du depot (`mise.toml` pour les versions,
# `mise.lock` pour l'origine des artefacts), puis pour chaque outil il trouve la
# version reellement presente et l'affiche. Il rend 1 si un outil requis manque :
# `jq`, `yq`, `kustomize`, `shellcheck`, `just` et le module Python `yaml`. Un outil
# que le pod ne peut pas telecharger (hote non autorise par la CiliumNetworkPolicy
# des pods d'agents) est signale sans faire echouer le controle.
#
# Sortie (stdout), une ligne par outil :
#   PREFLIGHT=OK       tool=<nom> version=<trouvee> expected=<voulue> path=<chemin>
#   PREFLIGHT=MISMATCH tool=<nom> version=<trouvee> expected=<voulue> path=<chemin>
#   PREFLIGHT=ABSENT   tool=<nom> expected=<voulue> reason=host_not_allowed host=<hote>
#   PREFLIGHT=MISSING  tool=<nom> expected=<voulue> reason=not_installed
# puis une ligne de verdict :
#   PREFLIGHT=PASS     required=<n> missing=<n> mismatch=<n> absent=<n>
#   PREFLIGHT=FAIL     required=<n> missing=<n> mismatch=<n> absent=<n> missing_tools=<liste>
#
# Codes de retour : 0 si les outils requis sont là, 1 sinon, 2 si le contrat
# d'outils du depot est illisible.
#
# Lecture seule, aucun appel réseau, aucun accès cluster.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
MISE_TOML="$REPO_ROOT/mise.toml"
MISE_LOCK="$REPO_ROOT/mise.lock"

# Meme version que scripts/policy-check.sh et .github/workflows/stateful-plan.yaml.
readonly PYYAML_PACKAGE="yaml"
readonly PYYAML_VERSION="6.0.2"

# Outils sans lesquels les controles du depot ne peuvent pas tourner.
readonly REQUIRED_TOOLS=(jq yq kustomize shellcheck just yaml)

# Hotes deja autorises au pod d'agent (CiliumNetworkPolicy optio-agents,
# k8s/applications/platform/optio/networkpolicy.yaml).
readonly ALLOWED_HOSTS=(
  github.com
  objects.githubusercontent.com
  pypi.org
  files.pythonhosted.org
  registry.npmjs.org
)

# Outil de mise.toml | binaire cherche dans le PATH.
readonly TOOL_BINARIES=(
  'jq|jq'
  'yq|yq'
  'just|just'
  'kustomize|kustomize'
  'helm|helm'
  'kubeconform|kubeconform'
  'kyverno|kyverno'
  'kubectl|kubectl'
  'shellcheck|shellcheck'
  'ripgrep|rg'
  'vale|vale'
  'prek|prek'
  'python|python3'
  'node|node'
)

is_required() {
  local candidate=$1 required
  for required in "${REQUIRED_TOOLS[@]}"; do
    [ "$candidate" = "$required" ] && return 0
  done
  return 1
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

# Commande qui affiche la version d'un outil.
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

# Versions voulues : `mise.toml`, section [tools] (une ligne `outil = "version"`).
read_mise_toml() {
  [ -r "$MISE_TOML" ] || return 1
  awk '
    /^\[tools\]$/ { in_tools = 1; next }
    /^\[/ { in_tools = 0; next }
    in_tools && /=/ {
      line = $0
      sub(/[ \t]*#.*$/, "", line)
      name = line
      sub(/[ \t]*=.*$/, "", name)
      version = line
      sub(/^[^=]*=[ \t]*"/, "", version)
      sub(/"[ \t]*$/, "", version)
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      if (name != "" && version != "") printf "%s\t%s\n", name, version
    }
  ' "$MISE_TOML"
}

# Origine des artefacts : `mise.lock`, section de la plateforme courante.
read_mise_lock_urls() {
  local platform=$1
  [ -r "$MISE_LOCK" ] || return 1
  awk -v plat="$platform" '
    /^\[\[tools\.[A-Za-z0-9._-]+\]\]$/ {
      name = $0
      sub(/^\[\[tools\./, "", name)
      sub(/\]\]$/, "", name)
      current = name
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
    in_platform && /^url = "/ {
      value = $0
      sub(/^url = "/, "", value)
      sub(/"$/, "", value)
      url[current] = value
      next
    }
    END {
      for (tool in url) printf "%s\t%s\n", tool, url[tool]
    }
  ' "$MISE_LOCK"
}

main() {
  local platform tool binary expected found path url host entry
  local missing=0 mismatch=0 absent=0 checked=0
  local versions_output urls_output
  local -a missing_tools=() tool_versions=() tool_urls=()

  case "$(uname -m)" in
    x86_64) platform="linux-x64" ;;
    aarch64 | arm64) platform="linux-arm64" ;;
    *)
      printf 'PREFLIGHT=FAIL reason=unsupported_arch arch=%s\n' "$(uname -m)"
      exit 2
      ;;
  esac

  versions_output="$(read_mise_toml)" || versions_output=""
  urls_output="$(read_mise_lock_urls "$platform")" || urls_output=""
  if [ -z "$versions_output" ]; then
    printf 'PREFLIGHT=FAIL reason=contract_unreadable file=%s\n' "$MISE_TOML" >&2
    exit 2
  fi
  mapfile -t tool_versions <<<"$versions_output"
  mapfile -t tool_urls <<<"$urls_output"

  declare -A VERSION=() URL=()
  for entry in "${tool_versions[@]}"; do
    VERSION["${entry%%$'\t'*}"]="${entry##*$'\t'}"
  done
  for entry in "${tool_urls[@]}"; do
    URL["${entry%%$'\t'*}"]="${entry##*$'\t'}"
  done

  for entry in "${TOOL_BINARIES[@]}"; do
    IFS='|' read -r tool binary <<<"$entry"
    expected="${VERSION[$tool]:-}"
    if [ -z "$expected" ]; then
      continue
    fi
    checked=$((checked + 1))
    path="$(command -v "$binary" 2>/dev/null || true)"
    if [ -z "$path" ]; then
      url="${URL[$tool]:-}"
      host=""
      [ -n "$url" ] && host="$(url_host "$url")"
      if [ -n "$host" ] && ! host_allowed "$host"; then
        # Le pod ne peut pas telecharger cet outil : signale, sans faire echouer.
        printf 'PREFLIGHT=ABSENT tool=%s expected=%s reason=host_not_allowed host=%s\n' "$tool" "$expected" "$host"
        absent=$((absent + 1))
        continue
      fi
      printf 'PREFLIGHT=MISSING tool=%s expected=%s reason=not_installed\n' "$tool" "$expected"
      missing=$((missing + 1))
      is_required "$tool" && missing_tools+=("$tool")
      continue
    fi
    found="$(detect_version "$tool" "$path")"
    if [ "$found" = "$expected" ]; then
      printf 'PREFLIGHT=OK tool=%s version=%s expected=%s path=%s\n' "$tool" "$found" "$expected" "$path"
    else
      printf 'PREFLIGHT=MISMATCH tool=%s version=%s expected=%s path=%s\n' "$tool" "${found:-none}" "$expected" "$path"
      mismatch=$((mismatch + 1))
    fi
  done

  # Module Python : les controles du depot lisent le module avec `python3 -I`
  # (mode isole), donc c'est le python du PATH qui compte.
  found=""
  if command -v python3 >/dev/null 2>&1; then
    found="$(python3 -I -c 'import yaml; print(yaml.__version__)' 2>/dev/null || true)"
  fi
  checked=$((checked + 1))
  if [ "$found" = "$PYYAML_VERSION" ]; then
    printf 'PREFLIGHT=OK tool=%s version=%s expected=%s\n' "$PYYAML_PACKAGE" "$found" "$PYYAML_VERSION"
  elif [ -n "$found" ]; then
    printf 'PREFLIGHT=MISMATCH tool=%s version=%s expected=%s\n' "$PYYAML_PACKAGE" "$found" "$PYYAML_VERSION"
    mismatch=$((mismatch + 1))
  else
    printf 'PREFLIGHT=MISSING tool=%s expected=%s reason=module_not_importable\n' "$PYYAML_PACKAGE" "$PYYAML_VERSION"
    missing=$((missing + 1))
    missing_tools+=("$PYYAML_PACKAGE")
  fi

  if [ "${#missing_tools[@]}" -gt 0 ]; then
    local joined=""
    for tool in "${missing_tools[@]}"; do
      joined="${joined:+$joined,}$tool"
    done
    printf 'PREFLIGHT=FAIL required=%d checked=%d missing=%d mismatch=%d absent=%d missing_tools=%s\n' \
      "${#REQUIRED_TOOLS[@]}" "$checked" "$missing" "$mismatch" "$absent" "$joined"
    exit 1
  fi
  printf 'PREFLIGHT=PASS required=%d checked=%d missing=%d mismatch=%d absent=%d\n' \
    "${#REQUIRED_TOOLS[@]}" "$checked" "$missing" "$mismatch" "$absent"
  exit 0
}

main "$@"
