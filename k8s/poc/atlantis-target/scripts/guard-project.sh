#!/usr/bin/env bash
set -euo pipefail
deny() { printf 'Atlantis target denied: %s\n' "$*" >&2; exit 1; }
[[ "$BASE_REPO_OWNER/$BASE_REPO_NAME" == SmadjaPaul/homelab-infra ]] || deny 'base repo'
[[ "$HEAD_REPO_OWNER/$HEAD_REPO_NAME" == "$BASE_REPO_OWNER/$BASE_REPO_NAME" ]] || deny 'fork'
[[ "$BASE_BRANCH_NAME" == main ]] || deny 'branch'
[[ -z "$COMMENT_ARGS" ]] || deny 'comment args'
[[ "$PROJECT_NAME" =~ ^[a-z0-9-]+$ ]] || deny 'name'
[[ "$REPO_REL_DIR" == "terraform/$PROJECT_NAME" ]] || deny 'directory'
[[ "$WORKSPACE" == default ]] || deny 'workspace'
[[ -f "$ATLANTIS_TARGET_PROJECTS_FILE" ]] || deny 'unmounted project registry'
grep -Fxq "  - name: $PROJECT_NAME" "$ATLANTIS_TARGET_PROJECTS_FILE" || deny 'unregistered project'
git rev-parse 'origin/main^{commit}' >/dev/null 2>&1 || deny 'base unavailable'
git rev-parse "$HEAD_COMMIT^{commit}" >/dev/null 2>&1 || deny 'head unavailable'
changed_root=false
while IFS= read -r -d '' path; do
  case "$path" in
    "terraform/$PROJECT_NAME/backend.tf"|"terraform/$PROJECT_NAME/provider.tf"|"terraform/$PROJECT_NAME/versions.tf"|"terraform/$PROJECT_NAME/.terraform.lock.hcl")
      deny "sensitive toolchain or state change: $path" ;;
    "terraform/$PROJECT_NAME/"*) changed_root=true ;;
    docs/*|tests/*) ;;
    *) deny "unexpected path: $path" ;;
  esac
done < <(git diff --name-only -z "origin/main...$HEAD_COMMIT" --)
[[ "$changed_root" == true ]] || deny 'no change in selected root'
# Not a sandbox: root-scoped identity and provider provenance are separate preplan gates.
printf 'Atlantis target root admission PASS: %s\n' "$PROJECT_NAME"
