#!/usr/bin/env bash
set -euo pipefail

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }
done

INSTALLATION_ID="${INSTALLATION_ID:-161984586}"
EXPECTED_REPOS_JSON='${EXPECTED_REPOS_JSON:-["SmadjaPaul/homelab-infra","SmadjaPaul/kube-ops"]}'

installations="$(
  gh api '/user/installations?per_page=100'
)"

installation="$(
  jq -c --argjson id "$INSTALLATION_ID" '
    [.installations[] | select(.id == $id)][0] // empty
  ' <<<"$installations"
)

if [[ -z "$installation" ]]; then
  echo "GITHUB_APP_INSTALLATION=FAIL"
  echo "GITHUB_APP_INSTALLATION_ID=$INSTALLATION_ID"
  echo "GITHUB_APP_REASON=installation_not_visible_to_current_gh_identity"
  exit 1
fi

repos="$(
  gh api "/user/installations/$INSTALLATION_ID/repositories?per_page=100"
)"

repo_names="$(
  jq -c '
    [.repositories[].full_name] | unique | sort
  ' <<<"$repos"
)

app_slug="$(jq -r '.app_slug // "UNKNOWN"' <<<"$installation")"
app_id="$(jq -r '.app_id // "UNKNOWN"' <<<"$installation")"
repo_selection="$(jq -r '.repository_selection // "UNKNOWN"' <<<"$installation")"
permissions="$(jq -c '.permissions // {}' <<<"$installation")"
events="$(jq -c '.events // [] | sort' <<<"$installation")"

target_repos_present="$(
  jq -n --argjson actual "$repo_names" --argjson expected "$EXPECTED_REPOS_JSON" '
    ($expected - $actual | length) == 0
  '
)"
scope_exact="$(
  jq -n --argjson actual "$repo_names" --argjson expected "$EXPECTED_REPOS_JSON" '
    ($actual | sort) == ($expected | sort)
  '
)"

baseline_permissions="$(
  jq -r '
    (.metadata == "read") and
    (.contents == "write") and
    (.pull_requests == "write")
  ' <<<"$permissions"
)"

unexpected_write_permissions="$(
  jq -c '
    [
      to_entries[]
      | select(.value == "write")
      | select(.key != "contents" and .key != "pull_requests")
      | .key
    ] | sort
  ' <<<"$permissions"
)"

unexpected_write_count="$(jq 'length' <<<"$unexpected_write_permissions")"

dangerous_permissions="$(
  jq -c '
    [
      to_entries[]
      | select(
          (.key == "administration" and .value != "none") or
          (.key == "actions" and .value == "write") or
          (.key | test("secret"; "i")) or
          (.key | test("^organization_"))
        )
      | {key, value}
    ]
  ' <<<"$permissions"
)"
dangerous_permission_count="$(jq 'length' <<<"$dangerous_permissions")"

printf 'GITHUB_APP_INSTALLATION=PASS\n'
printf 'GITHUB_APP_INSTALLATION_ID=%s\n' "$INSTALLATION_ID"
printf 'GITHUB_APP_SLUG=%s\n' "$app_slug"
printf 'GITHUB_APP_ID=%s\n' "$app_id"
printf 'GITHUB_APP_REPOSITORY_SELECTION=%s\n' "$repo_selection"
printf 'GITHUB_APP_REPOSITORIES=%s\n' "$repo_names"
printf 'GITHUB_APP_REPO_COUNT=%s\n' "$(jq 'length' <<<"$repo_names")"
printf 'GITHUB_APP_TARGET_REPOS_PRESENT=%s\n' "$([[ "$target_repos_present" == true ]] && echo YES || echo NO)"
printf 'GITHUB_APP_SCOPE_EXACT=%s\n' "$([[ "$scope_exact" == true ]] && echo YES || echo NO)"
printf 'GITHUB_APP_PERMISSIONS=%s\n' "$permissions"
printf 'GITHUB_APP_BASELINE_PERMISSIONS=%s\n' "$([[ "$baseline_permissions" == true ]] && echo YES || echo NO)"
printf 'GITHUB_APP_UNEXPECTED_WRITE_PERMISSIONS=%s\n' "$unexpected_write_permissions"
printf 'GITHUB_APP_UNEXPECTED_WRITE_COUNT=%s\n' "$unexpected_write_count"
printf 'GITHUB_APP_DANGEROUS_PERMISSIONS=%s\n' "$dangerous_permissions"
printf 'GITHUB_APP_DANGEROUS_PERMISSION_COUNT=%s\n' "$dangerous_permission_count"
printf 'GITHUB_APP_EVENTS=%s\n' "$events"

acceptable=YES
[[ "$repo_selection" == selected ]] || acceptable=NO
[[ "$target_repos_present" == true ]] || acceptable=NO
[[ "$scope_exact" == true ]] || acceptable=NO
[[ "$baseline_permissions" == true ]] || acceptable=NO
[[ "$unexpected_write_count" == 0 ]] || acceptable=NO
[[ "$dangerous_permission_count" == 0 ]] || acceptable=NO

printf 'GITHUB_APP_ACCEPTABLE=%s\n' "$acceptable"

[[ "$acceptable" == YES ]]
