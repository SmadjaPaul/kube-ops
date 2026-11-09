#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/k8s/poc/atlantis-target/scripts/guard-project.sh"
policy="$root/k8s/poc/atlantis-target/policies/plan-safety.rego"
for domain in apps infra; do
  file="$root/k8s/poc/atlantis-target/values-$domain.yaml"
  grep -Fxq 'disableApply: true' "$file"
  grep -Fxq 'disableApplyAll: true' "$file"
  grep -q 'ATLANTIS_ALLOW_COMMANDS: version' "$file"
  grep -q 'workflow: atlantis-target-deny' "$file"
  grep -q 'allowed_overrides: \[\]' "$file"
  grep -q 'allow_custom_workflows: false' "$file"
  grep -q "atlantis-target-$domain.yaml" "$file"
done
grep -q 'import rego.v1' "$policy"
grep -q 'action == "delete"' "$policy"
grep -q 'after_sensitive' "$policy"
bash -n "$guard"
case_run() {
  local scenario="$1" expected="$2" project="$3" dir head status
  dir="$(mktemp -d)"
  (
    set -e
    cd "$dir"
    git init -q
    git config user.name test
    git config user.email test@local
    mkdir -p terraform/aiostreams terraform/polyfin
    echo 'initial' > terraform/aiostreams/main.tf
    git add -A
    git commit -qm init
    git branch -M main
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
    git checkout -qb update
    case "$scenario" in
      safe) echo 'change' >> terraform/aiostreams/main.tf ;;
      backend) echo 'change' > terraform/aiostreams/backend.tf ;;
      other) echo 'change' > terraform/polyfin/main.tf ;;
    esac
    git add -A
    git commit -qm changed
    echo -e 'projects:\n  - name: aiostreams' > target.yaml
  )
  head="$(git -C "$dir" rev-parse HEAD)"
  set +e
  (
    cd "$dir"
    BASE_REPO_OWNER=SmadjaPaul BASE_REPO_NAME=homelab-infra \
    HEAD_REPO_OWNER=SmadjaPaul HEAD_REPO_NAME=homelab-infra \
    BASE_BRANCH_NAME=main HEAD_COMMIT="$head" \
    PROJECT_NAME="$project" REPO_REL_DIR="terraform/$project" \
    WORKSPACE=default COMMENT_ARGS='' \
    ATLANTIS_TARGET_PROJECTS_FILE="$dir/target.yaml" \
    bash "$guard"
  ) >/dev/null 2>&1
  status=$?
  set -e
  rm -rf "$dir"
  if [[ "$expected" == pass && "$status" != 0 ]] || [[ "$expected" == deny && "$status" == 0 ]]; then
    echo "Atlantis target case $scenario / $project expected $expected; got $status" >&2; exit 1
  fi
}
case_run safe pass aiostreams
case_run backend deny aiostreams
case_run other deny aiostreams
case_run safe deny polyfin
echo 'Atlantis target fail-closed contracts PASS'
