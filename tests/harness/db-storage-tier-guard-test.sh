#!/usr/bin/env bash
# PLT-344 lot 0: database volumes belong on longhorn-fast (golden path,
# homelab-infra docs/operations/db-storage-golden-path.md; rule of kube-ops#36).
# This guard refuses any database volume on longhorn-bulk (HDD) in k8s/, except
# the entries of tests/harness/db-storage-bulk-exceptions.tsv. Each exception
# carries a written reason; an entry that no longer matches a manifest fails
# too, so the list shrinks as databases move to longhorn-fast.
#
# Detected as a database volume on longhorn-bulk:
#   - CNPG Cluster: spec.storage.storageClass or spec.walStorage.storageClass;
#   - StatefulSet: a volumeClaimTemplate on longhorn-bulk and a database image
#     (postgres, mysql, mariadb, mongo, redis, valkey, percona);
#   - PersistentVolumeClaim on longhorn-bulk whose name looks like a database.
# Scope: plain manifests under k8s/ (Helm-rendered charts are not scanned).
# Self-test: the negative fixtures below must be refused.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exceptions="$repo_root/tests/harness/db-storage-bulk-exceptions.tsv"
command -v yq >/dev/null || { echo "ERROR: yq is required" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# scan DIR -> lines "Kind namespace/name file"
scan() {
  local dir="$1"
  find "$dir" \( -name '*.yaml' -o -name '*.yml' \) -type f | LC_ALL=C sort | while IFS= read -r f; do
    grep -q 'longhorn-bulk' "$f" || continue
    yq -o=json -I=0 'select(. != null)' "$f" 2>/dev/null | python3 -I -c '
import json, re, sys
f = sys.argv[1]
BULK = "longhorn-bulk"
DB_IMAGE = re.compile(r"^(postgres|postgresql|mysql|mariadb|mongo|mongodb|redis|valkey|percona[a-z0-9-]*)$")
DB_KEY = re.compile(r"^(mongodb|mongo|mysql|mariadb|postgresql|postgres|redis|valkey|database)$")
DB_NAME = re.compile(r"(mysql|mariadb|mongo|postgres|redis|valkey|database|(^|-)pg[0-9]*(-|$)|(^|-)db(-|$))")
def image_name(ref):
    # last path component without digest or tag (keeps registry ports out)
    return ref.split("@", 1)[0].rsplit("/", 1)[-1].split(":", 1)[0]
def bulk_in(node):
    if isinstance(node, dict):
        return any((k in ("storageClass", "storageClassName") and v == BULK) or bulk_in(v) for k, v in node.items())
    if isinstance(node, list):
        return any(bulk_in(v) for v in node)
    return False
def walk(node, path, ref):
    # Helm values (Argo valuesObject or values files): a database sub-chart
    # (mongodb:, mysql:, postgresql:, redis:...) whose persistence uses bulk.
    if isinstance(node, dict):
        for k, v in node.items():
            p = path + "." + str(k)
            if DB_KEY.match(str(k)) and isinstance(v, dict) and bulk_in(v):
                print("HelmValues", "%s:%s" % (ref, p.lstrip(".")), f)
            else:
                walk(v, p, ref)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (path, i), ref)
def classify(d):
    if not isinstance(d, dict):
        return
    kind = d.get("kind", ""); api = str(d.get("apiVersion", ""))
    if kind.endswith("List") and isinstance(d.get("items"), list):
        for item in d["items"]:
            classify(item)
        return
    md = d.get("metadata") or {}; spec = d.get("spec") or {}
    ref = "%s/%s" % (md.get("namespace", "-"), md.get("name", "?")) if kind else f
    hit = False
    if kind == "Cluster" and api.startswith("postgresql.cnpg.io/"):
        hit = any((spec.get(k) or {}).get("storageClass") == BULK for k in ("storage", "walStorage"))
    elif kind == "StatefulSet":
        vcts = spec.get("volumeClaimTemplates") or []
        bulk = any(((v.get("spec") or {}).get("storageClassName") == BULK) for v in vcts)
        pod = ((spec.get("template") or {}).get("spec") or {})
        imgs = [c.get("image", "") for c in (pod.get("containers") or []) + (pod.get("initContainers") or [])]
        hit = bulk and any(DB_IMAGE.match(image_name(i)) for i in imgs)
    elif kind == "PersistentVolumeClaim":
        hit = spec.get("storageClassName") == BULK and bool(DB_NAME.search(md.get("name", "")))
    if hit:
        print(kind, ref, f)
    elif kind not in ("Cluster", "StatefulSet", "PersistentVolumeClaim"):
        walk(d, "", ref)
for line in sys.stdin:
    line = line.strip()
    if not line or line == "null":
        continue
    try:
        classify(json.loads(line))
    except ValueError:
        continue
' "${f#"$repo_root"/}"
  done
}

# Self-test with negative and positive fixtures.
mkdir -p "$tmp/fx"
cat >"$tmp/fx/bad.yaml" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: bad-pg, namespace: fx}
spec:
  storage: {size: 1Gi, storageClass: longhorn-fast}
  walStorage: {size: 1Gi, storageClass: longhorn-bulk}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: bad-mysql, namespace: fx}
spec:
  template:
    spec:
      containers: [{name: db, image: "registry.example:5000/mysql@sha256:0123"}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {storageClassName: longhorn-bulk}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: app-mongodb, namespace: fx}
spec: {storageClassName: longhorn-bulk}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: chat, namespace: argocd}
spec:
  source:
    helm:
      valuesObject:
        mongodb:
          persistence: {storageClass: longhorn-bulk}
        imageVolume: {storageClassName: longhorn-bulk}
---
apiVersion: v1
kind: List
items:
  - apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata: {name: listed-pg, namespace: fx}
    spec:
      storage: {size: 1Gi, storageClass: longhorn-bulk}
EOF
cat >"$tmp/fx/good.yaml" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: good-pg, namespace: fx}
spec:
  storage: {size: 1Gi, storageClass: longhorn-fast}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: media-library, namespace: fx}
spec: {storageClassName: longhorn-bulk}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: jellyfin, namespace: fx}
spec:
  template:
    spec:
      containers: [{name: app, image: "ghcr.io/jellyfin/jellyfin:10.10.0"}]
  volumeClaimTemplates:
    - metadata: {name: media}
      spec: {storageClassName: longhorn-bulk}
EOF
(cd "$tmp" && repo_root="$tmp" scan "$tmp/fx") >"$tmp/fx.out"
expected="Cluster fx/bad-pg
Cluster fx/listed-pg
HelmValues argocd/chat:spec.source.helm.valuesObject.mongodb
PersistentVolumeClaim fx/app-mongodb
StatefulSet fx/bad-mysql"
if [ "$(cut -d' ' -f1,2 "$tmp/fx.out" | LC_ALL=C sort)" != "$expected" ]; then
  echo "ERROR: self-test failed; scanner output:" >&2
  cat "$tmp/fx.out" >&2
  exit 1
fi

scan "$repo_root/k8s" | LC_ALL=C sort -u >"$tmp/found"
# Exceptions: "Kind<TAB>namespace/name<TAB>reason", '#' comments.
grep -v '^#' "$exceptions" | grep . >"$tmp/exc" || true
bad=0
while IFS=$'\t' read -r kind ref reason; do
  if [ -z "${reason// /}" ]; then
    echo "ERROR: exception '$kind $ref' has no written reason ($exceptions)." >&2
    bad=1
  fi
done <"$tmp/exc"
while read -r kind ref file; do
  if ! awk -F'\t' -v k="$kind" -v r="$ref" '$1 == k && $2 == r { f = 1 } END { exit !f }' "$tmp/exc"; then
    echo "ERROR: database volume on longhorn-bulk: $kind $ref ($file)." >&2
    echo "       Databases and their WAL use longhorn-fast (homelab-infra docs/operations/db-storage-golden-path.md)." >&2
    bad=1
  fi
done <"$tmp/found"
while IFS=$'\t' read -r kind ref _; do
  if ! awk -v k="$kind" -v r="$ref" '$1 == k && $2 == r { f = 1 } END { exit !f }' "$tmp/found"; then
    echo "ERROR: stale exception '$kind $ref' matches no database on longhorn-bulk: remove it from $exceptions." >&2
    bad=1
  fi
done <"$tmp/exc"
if [ "$bad" -ne 0 ]; then exit 1; fi
echo "DB_STORAGE_TIER_GUARD=PASS ($(grep -c . "$tmp/found" || true) exceptions in use, self-test OK)"
