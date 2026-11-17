#!/usr/bin/env bash
# PLT-375 (X4): every Database of pg-shared-homelab must have a PostSync
# isolation Job named pg-shared-homelab-<db>-isolation that revokes CONNECT on
# that database from PUBLIC. A Database without its Job is refused.
#
# Parsing: yq (YAML 1.2 parser, same tool as db-storage-tier-guard-test.sh)
# turns every document into JSON, python3 -I reads the structure. A Database is
# matched on spec.cluster.name whatever the YAML style (flow {name: x}, block,
# quoted), so the guard does not depend on the layout of the file.
# Comments are dropped by the parser: a commented-out Job does not count.
# Multi-document files and kind: List are both walked.
# Self-test: the negative fixtures below must be refused, the positive ones
# accepted. Then the real tree (k8s/) is checked.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v yq >/dev/null || { echo "ERROR: yq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# scan DIR -> lines "DB <name> <file>" for each Database on pg-shared-homelab,
# and "JOB <job name> <db> <file>" for each PostSync Job revoking CONNECT from
# PUBLIC on <db>. Any parse error exits non-zero (fail closed, never silent).
scan() {
  # Pre-parse. Fichiers a syntaxe Helm ({{ }}) : parses un par un (erreur ou exclusion, comme avant).
  # Les autres : UN seul appel yq (sortie etiquetee par fichier). Seuls les fichiers dont le contenu
  # parse mentionne cnpg|PostSync|REVOKE sont inspectes (meme critere que l'ancienne boucle).
  # Si le lot echoue : repli sur un yq par fichier (messages d'erreur et arret identiques).
  local list="$tmp/pp.list" rel="$tmp/pp.rel" idx="$tmp/pp.idx" tl="$tmp/pp.tmpl" n f
  local helm_re='\{\{-|\.Values|include |toYaml|\{\{ *(if|range|with|define|end|template|block) '
  rm -rf "$tmp/pp"; mkdir -p "$tmp/pp"
  find "$1" \( -name '*.yaml' -o -name '*.yml' \) -type f | LC_ALL=C sort > "$list"
  awk '{print FNR"\t"$0}' "$list" > "$idx"
  : > "$tl"; if [ -s "$list" ]; then tr '\n' '\0' < "$list" | xargs -0 grep -lE "$helm_re" > "$tl" 2>/dev/null || true; fi
  awk -F'\t' 'NR==FNR{t[$0]=1; next} ($2 in t)' "$tl" "$idx" > "$tmp/pp.tidx"
  awk -F'\t' 'NR==FNR{t[$0]=1; next} !($2 in t)' "$tl" "$idx" > "$tmp/pp.pidx"
  : > "$rel"
  if [ -s "$tmp/pp.pidx" ] && cut -f2 "$tmp/pp.pidx" | tr '\n' '\0' | xargs -0 yq -o=json -I=0 'select(. != null) | {"file": filename, "doc": .}' \
      > "$tmp/pp.batch" 2>"$tmp/pp.err"; then
    python3 -I -c '
import json, re, sys
pidx = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
path2i = {p: int(i) for i, p in pidx}
docs = {int(i): [] for i, _ in pidx}
for line in open(sys.argv[2], encoding="utf-8"):
    if line.strip():
        obj = json.loads(line)
        docs[path2i[obj["file"]]].append(json.dumps(obj["doc"], ensure_ascii=False))
rel = open(sys.argv[5], "w", encoding="utf-8")
for i, path in pidx:
    i = int(i); text = "\n".join(docs[i]) + ("\n" if docs[i] else "")
    with open("%s/%d.json" % (sys.argv[3], i), "w", encoding="utf-8") as fh:
        fh.write(text)
    with open("%s/%d.rc" % (sys.argv[3], i), "w", encoding="utf-8") as fh:
        fh.write("0\n")
    if re.search(r"cnpg|PostSync|REVOKE", text):
        rel.write("%d\t%s\n" % (i, path))
rel.close()
' "$tmp/pp.pidx" "$tmp/pp.batch" "$tmp/pp" "$rel" "$rel"
    # fichiers a syntaxe Helm : parse individuel, toujours inspectes (erreur ou exclusion)
    while IFS=$'\t' read -r n f; do
      if yq -o=json -I=0 'select(. != null)' "$f" > "$tmp/pp/$n.json" 2>"$tmp/pp/$n.err"; then echo 0 > "$tmp/pp/$n.rc"; else echo 1 > "$tmp/pp/$n.rc"; fi
      printf '%s\t%s\n' "$n" "$f" >> "$rel"
    done < "$tmp/pp.tidx"
    LC_ALL=C sort -n -o "$rel" "$rel"
  else
    # repli : un yq par fichier, tous fichiers inspectes
    while IFS=$'\t' read -r n f; do
      if yq -o=json -I=0 'select(. != null)' "$f" > "$tmp/pp/$n.json" 2>"$tmp/pp/$n.err"; then echo 0 > "$tmp/pp/$n.rc"; else echo 1 > "$tmp/pp/$n.rc"; fi
    done < "$idx"
    cp "$idx" "$rel"
  fi
  while IFS=$'\t' read -r n f; do
    # Parse first: ExternalSecret templates ("{{ .KEY }}" inside quoted values,
    # kube-ops#1593 miniflux/externalsecret.yaml) are valid YAML and are scanned.
    # Only a file that does not parse AND carries Helm template syntax is out of
    # scope (not YAML until rendered, as in db-storage-tier-guard). If such a file
    # mentions CNPG or pg-shared-homelab it cannot be checked: fail closed.
    # A file that does not parse and has no Helm syntax is a hard error.
    cp "$tmp/pp/$n.json" "$tmp/doc.json"; cp "$tmp/pp/$n.err" "$tmp/yq.err" 2>/dev/null || : > "$tmp/yq.err"
    if [ "$(cat "$tmp/pp/$n.rc")" != 0 ]; then
      if grep -qE '\{\{-|\.Values|include |toYaml|\{\{ *(if|range|with|define|end|template|block) ' "$f"; then
        if grep -qE 'postgresql\.cnpg\.io|REVOKE CONNECT|pg-shared-homelab' "$f"; then
          echo "ERROR: ${f#"$1"/} is a Helm template that mentions CNPG: cannot be checked" >&2; exit 1
        fi
        continue
      fi
      echo "ERROR: cannot parse ${f#"$1"/} as YAML: $(head -1 "$tmp/yq.err")" >&2; exit 1
    fi
    # Only documents that can hold a Database or a PostSync Job go to python (speed):
    # every file is still parsed by yq above, so parse errors stay fatal.
    if grep -qE 'cnpg|PostSync|REVOKE' "$tmp/doc.json"; then
    python3 -I -c '
import json, re, sys
f = sys.argv[1]
TARGET = "pg-shared-homelab"
REVOKE = re.compile(r"REVOKE\s+CONNECT\s+ON\s+DATABASE\s+\"?([A-Za-z0-9_]+)\"?\s+FROM\s+PUBLIC", re.I)
def items(doc):
    if isinstance(doc, dict) and doc.get("kind") == "List":
        for it in doc.get("items") or []:
            yield from items(it)
    elif isinstance(doc, dict):
        yield doc
def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
def cluster_of(spec):
    c = spec.get("cluster")
    if isinstance(c, dict):
        return c.get("name")
    return c if isinstance(c, str) else None
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.strip()
    if not line or line == "null":
        continue
    for d in items(json.loads(line)):
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        spec = d.get("spec") or {}
        if kind == "Database" and str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io/") \
                and isinstance(spec, dict) and cluster_of(spec) == TARGET:
            name = spec.get("name") or meta.get("name")
            if name:
                print("DB", name, f)
        if kind == "Job" and meta.get("name"):
            hooks = [h.strip() for h in str((meta.get("annotations") or {}).get("argocd.argoproj.io/hook", "")).split(",")]
            if "PostSync" in hooks:
                for db in sorted({m.group(1) for s in strings(d) for m in REVOKE.finditer(s)}):
                    print("JOB", meta["name"], db, f)
' "$f" "$tmp/doc.json" || { echo "ERROR: cannot read ${f#"$1"/}" >&2; exit 1; }
    fi
  done < "$rel"
}

check() {
  local root="$1" out dbs db ok=0
  out="$(scan "$root")" || exit 1
  dbs="$(printf '%s\n' "$out" | awk '$1 == "DB"')"
  while read -r _ db file; do
    [ -n "${db:-}" ] || continue
    if ! printf '%s\n' "$out" | awk -v want="pg-shared-homelab-$db-isolation" -v d="$db" \
        '$1 == "JOB" && $2 == want && $3 == d {found = 1} END {exit !found}'; then
      echo "FAIL: Database $db (${file#"$root"/}) on pg-shared-homelab has no PostSync isolation Job pg-shared-homelab-$db-isolation revoking CONNECT from PUBLIC" >&2
      ok=1
    fi
  done <<< "$dbs"
  return "$ok"
}

# expect pass|fail DIR LABEL: fail must be a real refusal ("FAIL:" line), not
# a parse error, so a broken parser cannot pass the negative cases silently.
expect() {
  local want="$1" dir="$2" label="$3" msg="" got
  if msg="$(check "$dir" 2>&1)"; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "SELF-TEST FAIL: $label expected $want, got $got: $msg" >&2; exit 1
  fi
  if [ "$want" = fail ] && ! grep -q '^FAIL:' <<<"$msg"; then
    echo "SELF-TEST FAIL: $label refused without a FAIL line: $msg" >&2; exit 1
  fi
}

PROBE_JOB() { # PROBE_JOB NAME HOOK DB  -> a PostSync (or other hook) Job
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  namespace: databases
  annotations:
    argocd.argoproj.io/hook: $2
spec:
  template:
    spec:
      containers:
        - name: isolate
          args: ["psql -c 'REVOKE CONNECT ON DATABASE $3 FROM PUBLIC'"]
EOF
}

DB_FLOW='apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: {name: probe, namespace: databases}
spec:
  name: probe
  owner: probe
  cluster: {name: pg-shared-homelab}'

DB_BLOCK='apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: probe
  namespace: databases
spec:
  name: probe
  owner: probe
  cluster:
    name: pg-shared-homelab'

DB_QUOTED='apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: {name: probe, namespace: databases}
spec:
  name: probe
  owner: probe
  cluster: {name: "pg-shared-homelab"}'

# Positive: flow style + correct Job.
fx="$tmp/good-flow"; mkdir -p "$fx"
printf '%s\n' "$DB_FLOW" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync probe > "$fx/job.yaml"
expect pass "$fx" "flow Database + Job"

# Positive: block style + correct Job (the case that used to be ignored).
fx="$tmp/good-block"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync probe > "$fx/job.yaml"
expect pass "$fx" "block Database + Job"

# Positive: quoted cluster name + correct Job.
fx="$tmp/good-quoted"; mkdir -p "$fx"
printf '%s\n' "$DB_QUOTED" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync probe > "$fx/job.yaml"
expect pass "$fx" "quoted Database + Job"

# Positive: Database on another cluster is out of scope.
fx="$tmp/good-other-cluster"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" | sed 's/pg-shared-homelab/pg-other/' > "$fx/db.yaml"
expect pass "$fx" "Database on another cluster (out of scope)"

# Negative: flow style, no Job.
fx="$tmp/bad-flow"; mkdir -p "$fx"
printf '%s\n' "$DB_FLOW" > "$fx/db.yaml"
expect fail "$fx" "flow Database without Job"

# Negative: block style, no Job (regression: used to pass as "0 Database").
fx="$tmp/bad-block"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
expect fail "$fx" "block Database without Job"

# Negative: quoted cluster name, no Job.
fx="$tmp/bad-quoted"; mkdir -p "$fx"
printf '%s\n' "$DB_QUOTED" > "$fx/db.yaml"
expect fail "$fx" "quoted Database without Job"

# Negative: single-quoted cluster name, no Job.
fx="$tmp/bad-single-quoted"; mkdir -p "$fx"
printf '%s\n' "$DB_FLOW" | sed "s/{name: pg-shared-homelab}/{name: 'pg-shared-homelab'}/" > "$fx/db.yaml"
expect fail "$fx" "single-quoted Database without Job"

# Negative: Database is the second document of a multi-document file.
fx="$tmp/bad-multidoc"; mkdir -p "$fx"
{ printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: databases}\n---\n'; printf '%s\n' "$DB_BLOCK"; } > "$fx/db.yaml"
expect fail "$fx" "Database in second document, no Job"

# Negative: Database inside kind: List, no Job.
fx="$tmp/bad-list"; mkdir -p "$fx"
cat > "$fx/db.yaml" <<'EOF'
apiVersion: v1
kind: List
items:
  - apiVersion: postgresql.cnpg.io/v1
    kind: Database
    metadata: {name: probe, namespace: databases}
    spec:
      name: probe
      owner: probe
      cluster: {name: pg-shared-homelab}
EOF
expect fail "$fx" "Database inside kind: List, no Job"

# Negative: Job present only as comments.
fx="$tmp/bad-commented"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync probe | sed 's/^/# /' > "$fx/job.yaml"
expect fail "$fx" "Job only in comments"

# Negative: right name and revoke, but hook is Sync, not PostSync.
fx="$tmp/bad-sync-hook"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation Sync probe > "$fx/job.yaml"
expect fail "$fx" "Job with Sync hook instead of PostSync"

# Negative: right name, but it revokes another database.
fx="$tmp/bad-wrong-db"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync other > "$fx/job.yaml"
expect fail "$fx" "Job named for probe revoking another database"

# Negative: right revoke, but wrong Job name.
fx="$tmp/bad-wrong-name"; mkdir -p "$fx"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-other-isolation PostSync probe > "$fx/job.yaml"
expect fail "$fx" "Job with wrong name revoking probe"

# Positive: ESO template in the same file as a Database with its Job
# (kube-ops#1593 shape: "{{ .DB_PASSWORD }}" inside quoted values).
fx="$tmp/good-eso"; mkdir -p "$fx"
cat > "$fx/externalsecret.yaml" <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-runtime
  namespace: miniflux
spec:
  target:
    name: probe-runtime
    template:
      data:
        DATABASE_URL: "user=probe password={{ .DB_PASSWORD }} host=pg-shared-homelab-rw.databases.svc.cluster.local"
EOF
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
PROBE_JOB pg-shared-homelab-probe-isolation PostSync probe > "$fx/job.yaml"
expect pass "$fx" "ESO template file + Database + Job"

# Negative: ESO template must not hide a Database without its Job.
fx="$tmp/bad-eso-db"; mkdir -p "$fx"
cp "$tmp/good-eso/externalsecret.yaml" "$fx/"
printf '%s\n' "$DB_BLOCK" > "$fx/db.yaml"
expect fail "$fx" "ESO template file + Database without Job"

# Negative: Helm template (not YAML) that mentions CNPG: cannot be checked, refused.
fx="$tmp/bad-helm-cnpg"; mkdir -p "$fx"
cat > "$fx/db.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: {name: probe, namespace: databases}
spec:
  name: probe
  cluster: {name: pg-shared-homelab}
{{- end }}
EOF
if ( check "$fx" ) >/dev/null 2>&1; then echo "SELF-TEST FAIL: Helm template mentioning CNPG accepted" >&2; exit 1; fi

# Positive: Helm template that does not mention CNPG is out of scope, skipped.
fx="$tmp/good-helm-other"; mkdir -p "$fx"
printf '{{- if .Values.enabled }}\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\n{{- end }}\n' > "$fx/cm.yaml"
expect pass "$fx" "Helm template without CNPG (skipped)"

# Negative: unparsable YAML with no Helm syntax is a hard error.
fx="$tmp/bad-broken-template-like"; mkdir -p "$fx"
printf 'password: "{{ .DB_PASSWORD }}\n  cluster: [pg-shared-homelab\n' > "$fx/x.yaml"
if ( check "$fx" ) >/dev/null 2>&1; then echo "SELF-TEST FAIL: broken YAML with template-like text accepted" >&2; exit 1; fi

# Negative: unparsable YAML must stop the guard (non-zero), never pass it.
fx="$tmp/bad-unparsable"; mkdir -p "$fx"
printf 'kind: [Database\n  broken: {\n' > "$fx/db.yaml"
if ( check "$fx" ) >/dev/null 2>&1; then echo "SELF-TEST FAIL: unparsable YAML accepted" >&2; exit 1; fi

check "$repo_root/k8s" || exit 1
dbcount="$(scan "$repo_root/k8s" | awk '$1 == "DB"' | wc -l | tr -d ' ')"
echo "PG_SHARED_HOMELAB_ISOLATION=PASS (self-test ok, $dbcount Database on pg-shared-homelab)"
