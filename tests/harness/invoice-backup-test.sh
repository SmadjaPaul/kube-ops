#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/invoice-backup-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

backup_command="$(yq -r '.spec.jobTemplate.spec.template.spec.containers[0].command[2]' \
  "$repo_root/k8s/applications/business/invoice-ninja/backup-logical.yaml")"

printf '%s\n' "$backup_command" | bash -n
for expected in '--no-tablespaces' 'mysqladmin ping' 'test -w' '.mysql-latest.sql.tmp.$$'; do
  [[ "$backup_command" == *"$expected"* ]] || {
    printf 'ASSERTION_FAILED missing=%s\n' "$expected" >&2
    exit 1
  }
done

dump_command="$(awk '/^[[:space:]]*mysqldump / {capture=1} capture {print} capture && /ninja >/ {exit}' <<<"$backup_command")"
[[ "$dump_command" != *'--connect-timeout'* ]] || {
  echo 'ASSERTION_FAILED mysqldump has unsupported --connect-timeout option' >&2
  exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/mysqladmin" <<'SH'
#!/usr/bin/env sh
exit 0
SH
cat >"$tmp/bin/mysqldump" <<'SH'
#!/usr/bin/env sh
printf '%s\n' 'synthetic invoice-ninja schema'
SH
chmod +x "$tmp/bin/mysqladmin" "$tmp/bin/mysqldump"

portable_command="${backup_command//\/backup/$tmp/backup}"
PATH="$tmp/bin:$PATH" /bin/sh -ec "$portable_command"

[[ "$(cat "$tmp/backup/logical-backups/mysql-latest.sql")" == 'synthetic invoice-ninja schema' ]] || {
  echo 'ASSERTION_FAILED backup artifact was not atomically published' >&2
  exit 1
}
if find "$tmp/backup/logical-backups" -name '.mysql-latest.sql.tmp.*' -print -quit | grep -q .; then
  echo 'ASSERTION_FAILED temporary backup artifact was not cleaned' >&2
  exit 1
fi

printf '%s\n' 'INVOICE_BACKUP_CONTRACT_TEST=PASS'
