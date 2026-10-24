#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh"
test -f "$guard"

make_fixture() {
  local fixture base_commit
  fixture="$(mktemp -d)"
  git archive --format=tar HEAD | tar -x -C "$fixture"
  git -C "$fixture" init -q
  git -C "$fixture" config user.email harness-00b@homelab.local
  git -C "$fixture" config user.name HARNESS-00B
  mkdir -p "$fixture/.atlantis" "$fixture/terraform/github"
  cp "$repo_root/tests/fixtures/github-atlantis-admission/.atlantis/plan-only.yaml" "$fixture/.atlantis/plan-only.yaml"
  cp "$repo_root/tests/fixtures/github-atlantis-admission/backend.tf.fixture" "$fixture/terraform/github/backend.tf"
  printf '%s\n' 'provider "github" { app_auth {} }' >"$fixture/terraform/github/provider.tf"
  printf '%s\n' 'version = "= 6.13.0"' >"$fixture/terraform/github/versions.tf"
  printf '%s\n' 'managed_repository_settings = {}' >"$fixture/terraform/github/repositories.auto.tfvars"
  mkdir -p \
    "$fixture/terraform/cloudflare/modules/access" \
    "$fixture/terraform/cloudflare/modules/security-headers"
  printf '%s\n' '# access' >"$fixture/terraform/cloudflare/modules/access/README.md"
  printf '%s\n' 'default = true' >"$fixture/terraform/cloudflare/modules/security-headers/variables.tf"
  printf '%s\n' 'provider "cloudflare" {}' >"$fixture/terraform/cloudflare/modules/security-headers/provider.tf"
  git -C "$fixture" add -A
  git -C "$fixture" commit -qm base
  git -C "$fixture" branch -M main
  base_commit="$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" update-ref refs/remotes/origin/main "$base_commit"
  git -C "$fixture" checkout -qb change
  printf '%s\n' "$fixture"
}

run_case() {
  local name expected change_path fixture head output status
  name=$1
  expected=$2
  change_path=$3
  fixture="$(make_fixture)"
  trap 'rm -rf "$fixture"' RETURN

  case "$name" in
    readme-identified)
      printf '%s\n' '# generated documentation' >"$fixture/terraform/cloudflare/modules/access/README.md"
      ;;
    variables-denied)
      printf '%s\n' 'description = "changed"' >"$fixture/terraform/cloudflare/modules/security-headers/variables.tf"
      ;;
    default-true-to-false-denied)
      printf '%s\n' 'default = false' >"$fixture/terraform/cloudflare/modules/security-headers/variables.tf"
      ;;
    provider-denied)
      printf '%s\n' 'provider "cloudflare" { api_token = "REDACTED" }' >"$fixture/terraform/cloudflare/modules/security-headers/provider.tf"
      ;;
    readme-nested-denied)
      mkdir -p "$fixture/terraform/cloudflare/modules/access/nested"
      printf '%s\n' '# unexpected nested documentation' >"$fixture/terraform/cloudflare/modules/access/nested/README.md"
      change_path=terraform/cloudflare/modules/access/nested/README.md
      ;;
    mixed-readme-and-terraform-denied)
      printf '%s\n' '# generated documentation' >"$fixture/terraform/cloudflare/modules/access/README.md"
      printf '%s\n' 'description = "changed"' >"$fixture/terraform/cloudflare/modules/security-headers/variables.tf"
      ;;
    *)
      echo "unknown guard test case: $name" >&2
      return 1
      ;;
  esac

  git -C "$fixture" add -A
  git -C "$fixture" commit -qm "$name"
  head="$(git -C "$fixture" rev-parse HEAD)"
  set +e
  output="$(
    cd "$fixture"
    BASE_REPO_OWNER=SmadjaPaul \
    BASE_REPO_NAME=homelab-infra \
    HEAD_REPO_OWNER=SmadjaPaul \
    HEAD_REPO_NAME=homelab-infra \
    BASE_BRANCH_NAME=main \
    HEAD_COMMIT="$head" \
    DIR="$fixture" \
    bash "$guard" 2>&1
  )"
  status=$?
  set -e

  if test "$expected" = pass; then
    test "$status" -eq 0 || {
      printf 'GUARD_TEST=FAIL case=%s expected=pass status=%s output=%s\n' "$name" "$status" "$output" >&2
      return 1
    }
    printf 'GUARD_TEST=PASS case=%s\n' "$name"
  else
    test "$status" -ne 0 || {
      printf 'GUARD_TEST=FAIL case=%s expected=deny path=%s\n' "$name" "$change_path" >&2
      return 1
    }
    printf 'GUARD_TEST=PASS case=%s denied\n' "$name"
  fi
}

run_case readme-identified pass terraform/cloudflare/modules/access/README.md
run_case variables-denied deny terraform/cloudflare/modules/security-headers/variables.tf
run_case default-true-to-false-denied deny terraform/cloudflare/modules/security-headers/variables.tf
run_case provider-denied deny terraform/cloudflare/modules/security-headers/provider.tf
run_case readme-nested-denied deny terraform/cloudflare/modules/access/nested/README.md
run_case mixed-readme-and-terraform-denied deny terraform/cloudflare/modules/security-headers/variables.tf

printf 'GUARD_TEST=PASS all admission fixtures\n'
