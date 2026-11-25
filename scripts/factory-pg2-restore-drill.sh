#!/usr/bin/env bash
# PLT-369: full restore drill of the factory-platform logical dump (restic, R2)
# into a throwaway PostgreSQL container: no network, data on tmpfs, never pg2.
# Reads the repository with --no-lock, writes nothing to it. The plaintext dump
# exists only in the container tmpfs and is destroyed with the container.
# Prints counts and durations only, never a secret or a row.
#
# Needs restic and a running Docker engine. Credentials come from Doppler
# through scripts/doppler-safe.sh (read-only R2 key), see
# docs/operations/factory-platform-pg2-restore.md.
set -euo pipefail

: "${RESTIC_BACKUP_PASSWORD:?}" "${R2_S3_ENDPOINT:?}"
: "${R2_RESTIC_READER_ACCESS_KEY_ID:?}" "${R2_RESTIC_READER_SECRET_ACCESS_KEY:?}"
export RESTIC_REPOSITORY="s3:${R2_S3_ENDPOINT}/homelab-backup-restic/factory-platform"
export RESTIC_PASSWORD="$RESTIC_BACKUP_PASSWORD"
export AWS_ACCESS_KEY_ID="$R2_RESTIC_READER_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_RESTIC_READER_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto

# Same image as the dump CronJob and the pg2 Cluster (17.7).
image="ghcr.io/cloudnative-pg/postgresql:17.7-system-trixie@sha256:08775f8bdeb112878b8f2ef63578c47959ee332fc9e076d5d6735a710c4500e2"
name="plt369-drill-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

in_pg() { docker exec -i "$name" "$@"; }
sql() { in_pg psql -h /drill -U postgres -d factory_restore -Atc "$1"; }
now() { date +%s; }

t0="$(now)"
snapshot="$(restic snapshots --no-lock --json --latest 1 \
  --host factory-platform-restic --tag factory-platform-postgres |
  python3 -I -c 'import json,sys
s=json.load(sys.stdin)
print(max(s,key=lambda x:x["time"])["short_id"], max(s,key=lambda x:x["time"])["time"]) if s else None')"
read -r id taken <<<"$snapshot"
[ -n "${id:-}" ] || { echo "FAIL no snapshot"; exit 1; }
echo "snapshot=$id taken=$taken"

docker run -d --rm --name "$name" --network none --user 26:26 \
  --tmpfs /drill:rw,size=3g,uid=26,gid=26,mode=0700 "$image" sleep 3600 >/dev/null
echo "network=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")"
in_pg initdb -D /drill/data -U postgres >/dev/null
in_pg pg_ctl -D /drill/data -l /drill/pg.log -w -o "-c listen_addresses='' -k /drill" start >/dev/null
t1="$(now)"

restic dump --no-lock "$id" /factory-platform-postgres.dump | in_pg sh -c 'cat > /drill/factory.dump'
t2="$(now)"
echo "dump_bytes=$(in_pg stat -c %s /drill/factory.dump)"
toc="$(in_pg pg_restore --list /drill/factory.dump)"
echo "toc_table_data=$(grep -c ' TABLE DATA ' <<<"$toc")"

in_pg createdb -h /drill -U postgres factory_restore
in_pg pg_restore -h /drill -U postgres --no-owner --no-privileges --exit-on-error \
  -d factory_restore /drill/factory.dump
t3="$(now)"
echo "pg_restore=PASS"

for table in public.raw_events raw.events control.runs \
  public.github_collection_runs public.github_collection_watermarks; do
  echo "count $table=$(sql "SELECT count(*) FROM $table")"
done
echo "tables_by_schema:"
sql "SELECT schemaname, count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') GROUP BY 1 ORDER BY 1"
echo "control_rows=$(sql "SELECT coalesce(sum((xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint), 0) FROM pg_tables WHERE schemaname = 'control'")"
echo "latest raw_events columns:"
sql "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='raw_events'"
echo "raw.events triggers=$(sql "SELECT coalesce(string_agg(tgname, ','), 'NONE') FROM pg_trigger WHERE tgrelid = 'raw.events'::regclass AND NOT tgisinternal")"
echo "database_size=$(sql "SELECT pg_size_pretty(pg_database_size(current_database()))")"
echo "seconds setup=$((t1 - t0)) download=$((t2 - t1)) restore=$((t3 - t2)) total=$((t3 - t0))"
echo "DRILL=PASS"
