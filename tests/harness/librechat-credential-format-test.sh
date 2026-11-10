#!/usr/bin/env bash
set -euo pipefail

# Safe operator-side checker. Values are accepted only through the process
# environment, are never echoed, and are not written to a file. Missing input
# is deliberately distinct from a failed format check.

format_status=0
missing_input=0

check_hex() {
  local variable_name="$1"
  local expected_length="$2"
  local value="${!variable_name-}"

  if [[ -z "${!variable_name+x}" ]]; then
    printf '%s=NOT_EXECUTED\n' "$variable_name"
    missing_input=1
    return
  fi

  if [[ "${#value}" -eq "$expected_length" && "$value" =~ ^[0-9A-Fa-f]+$ ]]; then
    printf '%s=PASS\n' "$variable_name"
  else
    printf '%s=FAIL\n' "$variable_name"
    format_status=1
  fi
}

check_hex CREDS_KEY 64
check_hex CREDS_IV 32

if [[ "$format_status" -ne 0 ]]; then
  printf 'LIBRECHAT_CREDENTIAL_FORMAT=FAIL\n'
  exit 1
fi

if [[ "$missing_input" -ne 0 ]]; then
  printf 'LIBRECHAT_CREDENTIAL_FORMAT=NOT_EXECUTED\n'
  exit 2
fi

printf 'LIBRECHAT_CREDENTIAL_FORMAT=PASS\n'
