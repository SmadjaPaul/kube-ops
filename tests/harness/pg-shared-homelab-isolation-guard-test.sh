#!/usr/bin/env bash
# PLT-375 (X4): every Database of pg-shared-homelab must have a PostSync
# isolation Job named pg-shared-homelab-<db>-isolation that revokes CONNECT on
# that database from PUBLIC. A Database without its Job is refused.
# Self-test on fixtures first, then the real tree.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Prints "DB <name> <file>" for each Database on pg-shared-homelab, and
# "JOB <name> <db>" for each PostSync Job revoking CONNECT from PUBLIC on <db>.
scan() {
  find "$1" \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort | while IFS= read -r f; do
    awk -v file="$f" '
      function val(v) { gsub(/^["\x27]|["\x27]$/, "", v); return v }
      function flush() {
        if (kind == "Database" && api ~ /^postgresql\.cnpg\.io\// && cluster_hit && specname != "")
          print "DB " specname " " file
        if (kind == "Job" && postsync && revoked != "" && metaname != "")
          print "JOB " metaname " " revoked
        kind = ""; api = ""; metaname = ""; specname = ""; section = ""
        cluster_hit = 0; postsync = 0; revoked = ""
      }
      /^---/ { flush(); next }
      /^[^ #]/ && !/^metadata:/ && !/^spec:/ { section = "" }
      /^kind:[ ]/ { kind = val($2) }
      /^apiVersion:[ ]/ { api = val($2) }
      /^metadata:/ {
        section = "meta"
        if (match($0, /name: *[^,} ]+/)) { metaname = val(substr($0, RSTART + 5, RLENGTH - 5)); gsub(/ /, "", metaname) }
        next
      }
      /^spec:/ { section = "spec"; next }
      section == "meta" && /^  name:[ ]/ && metaname == "" { metaname = val($2) }
      section == "spec" && /^  name:[ ]/ && specname == "" { specname = val($2) }
      /cluster:/ && /pg-shared-homelab/ { cluster_hit = 1 }
      /argocd.argoproj.io\/hook: *PostSync/ { postsync = 1 }
      match($0, /REVOKE CONNECT ON DATABASE [a-z0-9_]+ FROM PUBLIC/) {
        s = substr($0, RSTART, RLENGTH); split(s, w, " "); revoked = w[5]
      }
      END { flush() }' "$f"
  done
}

check() {
  local root="$1" dbs jobs db ok=0
  dbs="$(scan "$root" | awk '$1 == "DB" {print}')"
  jobs="$(scan "$root" | awk '$1 == "JOB" {print}')"
  while read -r _ db file; do
    [ -n "${db:-}" ] || continue
    if ! printf '%s\n' "$jobs" | awk -v want="pg-shared-homelab-$db-isolation" -v d="$db" \
        '$2 == want && $3 == d {found = 1} END {exit !found}'; then
      echo "FAIL: Database $db (${file#"$root"/}) on pg-shared-homelab has no PostSync isolation Job pg-shared-homelab-$db-isolation revoking CONNECT from PUBLIC" >&2
      ok=1
    fi
  done <<< "$dbs"
  return "$ok"
}

# Self-test: a Database without its Job must fail; with its Job it must pass.
fx_bad="$tmp/bad"; fx_good="$tmp/good"
mkdir -p "$fx_bad" "$fx_good"
cat > "$fx_bad/db.yaml" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: {name: probe, namespace: databases}
spec:
  name: probe
  owner: probe
  cluster: {name: pg-shared-homelab}
EOF
cp "$fx_bad/db.yaml" "$fx_good/db.yaml"
cat > "$fx_good/job.yaml" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-shared-homelab-probe-isolation
  namespace: databases
  annotations:
    argocd.argoproj.io/hook: PostSync
spec:
  template:
    spec:
      containers:
        - name: isolate
          args: ["psql -c 'REVOKE CONNECT ON DATABASE probe FROM PUBLIC'"]
EOF
if check "$fx_bad" 2>/dev/null; then echo "SELF-TEST FAIL: Database without Job accepted" >&2; exit 1; fi
check "$fx_good" || { echo "SELF-TEST FAIL: Database with Job refused" >&2; exit 1; }

check "$repo_root/k8s" || exit 1
dbcount="$(scan "$repo_root/k8s" | awk '$1 == "DB"' | wc -l | tr -d ' ')"
echo "PG_SHARED_HOMELAB_ISOLATION=PASS (self-test ok, $dbcount Database on pg-shared-homelab)"
