#!/usr/bin/env bash
set -euo pipefail

repo_root="${AFFECTED_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"
started_at="$(date +%s)"
# shellcheck source=affected-tests.conf
source scripts/affected-tests.conf

mode=run
base_ref="${GITHUB_BASE_SHA:-}"
if [[ "${1:-}" == "--select" || "${1:-}" == "--run" ]]; then
  mode="${1#--}"
  shift
fi
[[ -z "${1:-}" ]] || base_ref="$1"
if [[ -z "$base_ref" ]]; then
  base_ref="$(git merge-base origin/main HEAD 2>/dev/null || git rev-parse HEAD)"
fi
git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 || {
  echo "AFFECTED_TESTS=BLOCKED reason=invalid_base_ref base=$base_ref" >&2
  exit 2
}

mapfile -t changed_files < <(
  { git diff --name-only "$base_ref" -- .; git diff --cached --name-only -- .; } |
    sed '/^$/d' | sort -u
)
all_roots=("${AFFECTED_INFRASTRUCTURE_ROOTS[@]}" "${AFFECTED_APPLICATION_ROOTS[@]}")
selected=()
add_root() {
  local root=$1 existing
  for existing in "${selected[@]:-}"; do [[ "$existing" == "$root" ]] && return; done
  selected+=("$root")
}
add_all() { local root; for root in "${all_roots[@]}"; do add_root "$root"; done; }

critical=no
for file in "${changed_files[@]:-}"; do
  classified=no
  case "$file" in
    k8s/infrastructure/*|k8s/bootstrap/*|scripts/*|tests/*|.justfile|package.json|.github/workflows/*|.agents/*|AGENTS.md|README.md)
      classified=yes
      critical=yes
      add_all;;
    k8s/applications/*)
      classified=yes
      critical=yes
      matched=no
      for root in "${AFFECTED_APPLICATION_ROOTS[@]}"; do
        case "$file" in
          "$root"/*|"$root") add_root "$root"; matched=yes;;
        esac
      done
      # A shared application Kustomize base selects all generated roots below it.
      if [[ "$file" == k8s/applications/*/kustomization.y*ml ]]; then
        prefix="${file%/*}"
        for root in "${AFFECTED_APPLICATION_ROOTS[@]}"; do
          case "$root/" in
            "$prefix"/*) add_root "$root"; matched=yes;;
          esac
        done
      fi
      # An application path outside the active root list is safer as a
      # repository-wide change than as an empty validation set.
      [[ "$matched" == yes ]] || add_all;;
  esac
  if [[ "$classified" == no ]]; then
    critical=yes
    add_all
  fi
done

if ((${#changed_files[@]} == 0)); then
  echo "AFFECTED_TESTS=EMPTY reason=no_diff base=$base_ref duration_seconds=$(( $(date +%s) - started_at ))"
  exit 0
fi
if [[ "$critical" == yes && ${#selected[@]} -eq 0 ]]; then add_all; fi
if [[ "$critical" == yes && ${#selected[@]} -eq 0 ]]; then
  echo "AFFECTED_TESTS=BLOCKED reason=zero_critical_tests" >&2
  exit 2
fi
echo "AFFECTED_BASE=$base_ref"
echo "AFFECTED_FILES=${#changed_files[@]}"
echo "AFFECTED_CRITICAL=$critical"
echo "AFFECTED_TESTS_BEGIN"
while IFS= read -r root; do echo "render:$root"; done < <(printf '%s\n' "${selected[@]}" | sort -u)
[[ "$critical" == yes ]] && echo "contract:repository-boundary"
echo "AFFECTED_TESTS_END"

if ((${#selected[@]} == 0)); then
  echo "AFFECTED_TESTS=EMPTY reason=non_kubernetes_diff duration_seconds=$(( $(date +%s) - started_at ))"
  exit 0
fi
if [[ "$mode" == select ]]; then
  echo "AFFECTED_TESTS=SELECTED count=${#selected[@]}"
  exit 0
fi
for command in kustomize kubeconform; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "AFFECTED_TESTS=BLOCKED reason=missing_validator validator=$command duration_seconds=$(( $(date +%s) - started_at ))" >&2
    exit 2
  }
done
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-affected.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
while IFS= read -r root; do
  [[ -f "$root/kustomization.yaml" || -f "$root/kustomization.yml" ]] || {
    echo "AFFECTED_TESTS=BLOCKED reason=missing_kustomization root=$root duration_seconds=$(( $(date +%s) - started_at ))" >&2
    exit 2
  }
  output="$tmp_dir/${root//\//_}.yaml"
  echo "AFFECTED_RENDER root=$root"
  kustomize build --enable-helm "$root" >"$output"
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.36.0 <"$output"
done < <(printf '%s\n' "${selected[@]}" | sort -u)
if command -v kyverno >/dev/null 2>&1 && [[ -f k8s/infrastructure/security/policies/kyverno-policies.yaml ]]; then
  echo "AFFECTED_KYVERNO=AVAILABLE policy_source=k8s/infrastructure/security/policies/kyverno-policies.yaml"
else
  echo "AFFECTED_KYVERNO=NOT_RUN reason=kyverno_cli_unavailable_or_no_active_policy_tests"
fi
echo "AFFECTED_TESTS=PASS count=${#selected[@]} duration_seconds=$(( $(date +%s) - started_at ))"
