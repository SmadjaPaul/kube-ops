#!/usr/bin/env bash
# Lot 0 of docs/architecture/secrets-migration-spec.md: static contract of the secrets generated
# inside the cluster (ESO generator, CreatedOnce) and of the stores k8s-auth / k8s-databases.
# Checked on the RENDERED tree (same roots and render cache as scripts/policy-check.sh):
#   1. every ExternalSecret that references a generatorRef has refreshPolicy CreatedOnce;
#   2. every generated source in namespace auth or databases has creationPolicy Orphan and the
#      annotation kube-ops.io/secret-class;
#   3. every Role bound to a ServiceAccount eso-k8s-*-reader: verbs == [get], resources == [secrets],
#      resourceNames not empty, containing the sentinel eso-k8s-sentinel-none, other names matching
#      ^oidc-[a-z0-9-]+$ (auth) or ^pg-[a-z0-9-]+$ (databases); each k8s-* store has such a Role;
#   4. every remoteRef.key read through k8s-auth / k8s-databases is listed in resourceNames of the
#      Role of that store and has a source (ExternalSecret with the same target.name) in the source
#      namespace;
#   5. a generator whose template key looks like a data-encryption key (T6) is refused, unless the
#      source is class T4 AND carries the annotation kube-ops.io/not-data-key with a justification;
#   6. self-test: one negative fixture per rule must be refused (with the expected rule code), the
#      positive fixtures accepted. No secret value is read: only names, kinds and policies.
# Fixtures live in mktemp; nothing is written in the repository; no fixed port.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
for t in yq python3 kustomize helm; do
  command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 1; }
done
tmp="$(mktemp -d "${TMPDIR:-/tmp}/eso-generated-contract.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------------------------
# Analyzer: reads JSON-lines documents (one Kubernetes object per line), prints
# "VIOLATION <code> <ns>/<Kind>/<name> <detail>" and exits 1 when there is any.
# ---------------------------------------------------------------------------------------------
cat > "$tmp/analyze.py" <<'PYEOF'
import json
import re
import sys

SENTINEL = "eso-k8s-sentinel-none"
STORES = {"k8s-auth": ("auth", "oidc-", r"^oidc-[a-z0-9-]+$"), "k8s-databases": ("databases", "pg-", r"^pg-[a-z0-9-]+$")}
GEN_NS = {"auth", "databases"}
T6 = re.compile(r"ENCRYPT|KEY_BASE|APP_KEY|MASTER_KEY|RESTIC|REPOSITORY_PASSWORD|SECRET_KEY")
READER_SA = re.compile(r"^eso-k8s-[a-z0-9-]+-reader$")


def load(paths):
    docs = {}
    for p in paths:
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                d = json.loads(line)
                if isinstance(d, dict) and d.get("kind"):
                    md = d.get("metadata") or {}
                    # kustomize `namespace:` also stamps unknown cluster-scoped CRD kinds: ignore it.
                    ns = "" if d["kind"] == "ClusterSecretStore" else md.get("namespace", "")
                    docs[(d["kind"], ns, md.get("name", ""))] = d
    return docs


def spec(d):
    return d.get("spec") or {}


def refs_generator(es):
    s = spec(es)
    for item in (s.get("dataFrom") or []) + (s.get("data") or []):
        if isinstance(item, dict) and isinstance(item.get("sourceRef"), dict) and "generatorRef" in item["sourceRef"]:
            return True
    return False


def target_name(es):
    return ((spec(es).get("target") or {}).get("name")) or es["metadata"]["name"]


def template_keys(es):
    t = (spec(es).get("target") or {}).get("template") or {}
    return list((t.get("data") or {}).keys())


def main(argv):
    require = "--require-stores" in argv
    paths = [a for a in argv if not a.startswith("--")]
    docs = load(paths)
    out = []

    def bad(code, d, detail):
        md = d.get("metadata") or {}
        out.append("VIOLATION %s %s/%s/%s %s" % (code, md.get("namespace", ""), d.get("kind"), md.get("name", ""), detail))

    ess = [d for (k, _, _), d in docs.items() if k == "ExternalSecret"]

    # Rules 1, 2, 5: generated sources
    for es in ess:
        if not refs_generator(es):
            continue
        s = spec(es)
        ns = es["metadata"].get("namespace", "")
        ann = es["metadata"].get("annotations") or {}
        if s.get("refreshPolicy") != "CreatedOnce":
            bad("generator-not-createdonce", es, "refreshPolicy must be CreatedOnce")
        if ns in GEN_NS:
            if (s.get("target") or {}).get("creationPolicy") != "Orphan":
                bad("source-not-orphan", es, "creationPolicy must be Orphan in auth/databases")
            if not ann.get("kube-ops.io/secret-class"):
                bad("source-without-class", es, "annotation kube-ops.io/secret-class is required")
        keys = [k.upper().replace("-", "_") for k in template_keys(es)]
        hit = [k for k in keys if T6.search(k)]
        if hit:
            allowed = ann.get("kube-ops.io/secret-class") == "T4" and str(ann.get("kube-ops.io/not-data-key", "")).strip() != ""
            if not allowed:
                bad("generator-t6-key", es, "key looks like a data-encryption key (T6): generate it with OpenTofu/Doppler, or class T4 + kube-ops.io/not-data-key")

    # Rule 3: Roles of the store readers
    bindings = [d for (k, _, _), d in docs.items() if k in ("RoleBinding", "ClusterRoleBinding")]
    role_names = {}  # (ns, store) -> set(resourceNames)
    sa_to_store = {}
    for st, (ns, _, _) in STORES.items():
        sa_to_store["eso-%s-reader" % st] = st
    for b in bindings:
        subs = [s for s in (b.get("subjects") or []) if s.get("kind") == "ServiceAccount" and READER_SA.match(s.get("name", ""))]
        if not subs:
            continue
        ns = b["metadata"].get("namespace", "")
        ref = b.get("roleRef") or {}
        if b["kind"] != "RoleBinding" or ref.get("kind") != "Role":
            bad("reader-bound-cluster-wide", b, "eso-k8s-*-reader must be bound by a RoleBinding to a Role in the source namespace")
            continue
        role = docs.get(("Role", ns, ref.get("name", "")))
        if role is None:
            bad("reader-role-missing", b, "RoleBinding refers to a missing Role %s" % ref.get("name"))
            continue
        store = sa_to_store.get(subs[0]["name"])
        names = set()
        rules = role.get("rules") or []
        if not rules:
            bad("role-no-rules", role, "no rule")
        has_names = False
        for r in rules:
            if r.get("verbs") != ["get"]:
                bad("role-verbs", role, "verbs must be exactly [get]")
            if r.get("resources") != ["secrets"]:
                bad("role-resources", role, "resources must be exactly [secrets]")
            if r.get("apiGroups") != [""]:
                bad("role-apigroups", role, 'apiGroups must be [""]')
            rn = r.get("resourceNames")
            if not rn:
                bad("role-resourcenames-empty", role, "resourceNames empty or absent: it would grant every Secret of the namespace")
            else:
                has_names = True
                names.update(rn)
        if has_names and SENTINEL not in names:
            bad("role-no-sentinel", role, "resourceNames must contain %s" % SENTINEL)
        pattern = STORES[store][2] if store else None
        for n in sorted(names - {SENTINEL}):
            if pattern is None or not re.match(pattern, n) or ns != STORES[store][0]:
                bad("role-name-not-allowed", role, "resourceName %s does not follow the store convention" % n)
        if store:
            role_names[store] = names
    for st, (ns, _, _) in STORES.items():
        store = docs.get(("ClusterSecretStore", "", st))
        if store is None:
            if require:
                out.append("VIOLATION store-missing //ClusterSecretStore/%s not rendered" % st)
            continue
        kp = (spec(store).get("provider") or {}).get("kubernetes") or {}
        if kp.get("remoteNamespace") != ns:
            bad("store-namespace", store, "remoteNamespace must be %s" % ns)
        if st not in role_names:
            bad("store-without-role", store, "no RoleBinding/Role for ServiceAccount eso-%s-reader in %s" % (st, ns))

    # Rule 4: keys read through the stores
    sources = {}
    for es in ess:
        if refs_generator(es):
            sources.setdefault(es["metadata"].get("namespace", ""), set()).add(target_name(es))
    for es in ess:
        s = spec(es)
        store = (s.get("secretStoreRef") or {}).get("name")
        if store not in STORES:
            continue
        src_ns = STORES[store][0]
        for item in s.get("data") or []:
            key = ((item or {}).get("remoteRef") or {}).get("key")
            if not key:
                continue
            if key not in role_names.get(store, set()):
                bad("key-not-in-role", es, "remoteRef.key %s is not in resourceNames of the %s reader Role" % (key, store))
            if key not in sources.get(src_ns, set()):
                bad("key-without-source", es, "remoteRef.key %s has no generated source (target.name) in namespace %s" % (key, src_ns))

    for line in sorted(set(out)):
        print(line)
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

# ---------------------------------------------------------------------------------------------
# Fixtures: a compliant world (both stores, one source and one copy each) and one mutation per rule.
# ---------------------------------------------------------------------------------------------
cat > "$tmp/fixtures.py" <<'PYEOF'
import copy
import json
import os
import sys

out = sys.argv[1]
GEN = {"apiVersion": "generators.external-secrets.io/v1alpha1", "kind": "Password", "name": "x"}


def store(st, ns):
    return {"apiVersion": "external-secrets.io/v1", "kind": "ClusterSecretStore", "metadata": {"name": st},
            "spec": {"provider": {"kubernetes": {"remoteNamespace": ns, "auth": {"serviceAccount": {"name": "eso-%s-reader" % st, "namespace": "external-secrets"}}}}}}


def role(st, ns, names):
    return {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {"name": "eso-%s-reader" % st, "namespace": ns},
            "rules": [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"], "resourceNames": ["eso-k8s-sentinel-none"] + names}]}


def binding(st, ns, kind="RoleBinding", rkind="Role"):
    return {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": kind, "metadata": {"name": "eso-%s-reader" % st, "namespace": ns},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": rkind, "name": "eso-%s-reader" % st},
            "subjects": [{"kind": "ServiceAccount", "name": "eso-%s-reader" % st, "namespace": "external-secrets"}]}


def source(name, ns, klass, key):
    return {"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret",
            "metadata": {"name": name, "namespace": ns, "annotations": {"kube-ops.io/secret-class": klass}},
            "spec": {"refreshPolicy": "CreatedOnce", "target": {"name": name, "creationPolicy": "Orphan",
                                                                 "template": {"engineVersion": "v2", "data": {key: "{{ .password }}"}}},
                     "dataFrom": [{"sourceRef": {"generatorRef": dict(GEN, name=name)}}]}}


def copy_es(name, ns, st, key):
    return {"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret", "metadata": {"name": name, "namespace": ns},
            "spec": {"refreshInterval": "1h", "secretStoreRef": {"kind": "ClusterSecretStore", "name": st},
                     "target": {"name": name, "creationPolicy": "Owner"},
                     "data": [{"secretKey": "k", "remoteRef": {"key": key, "property": "P"}}]}}


def world():
    return {
        "store-auth": store("k8s-auth", "auth"), "store-db": store("k8s-databases", "databases"),
        "role-auth": role("k8s-auth", "auth", ["oidc-app"]), "role-db": role("k8s-databases", "databases", ["pg-app"]),
        "rb-auth": binding("k8s-auth", "auth"), "rb-db": binding("k8s-databases", "databases"),
        "src-auth": source("oidc-app", "auth", "T3", "APP_OIDC_CLIENT_SECRET"),
        "src-db": source("pg-app", "databases", "T1", "password"),
        "copy-auth": copy_es("app-oidc", "app", "k8s-auth", "oidc-app"),
        "copy-db": copy_es("app-db", "app", "k8s-databases", "pg-app"),
        # same shape as grafana-admin-credentials and factory-platform-postgresql-source: outside auth/databases
        "grafana": dict(source("grafana-admin-credentials", "monitoring", "T4", "admin-password"),
                        ),
    }


def _t4(justified):
    d = source("searxng-session", "searxng", "T4", "SEARXNG_SECRET_KEY")
    if justified:
        d["metadata"]["annotations"]["kube-ops.io/not-data-key"] = "session cookie signing only, nothing persisted is encrypted with it"
    return d


fixtures = []  # (name, expected code or None, world)


def add(name, code, fn=None):
    w = world()
    if fn:
        fn(w)
    fixtures.append((name, code, w))


add("good-world", None)
add("good-world-sentinel-only", None, lambda w: (w["role-auth"]["rules"][0].update(resourceNames=["eso-k8s-sentinel-none"]),
                                                  [w.pop(k) for k in ("src-auth", "copy-auth")]))
add("good-t4-with-justification", None, lambda w: w.update(sess=_t4(True)))
add("good-owner-outside-auth-databases", None, lambda w: w["grafana"]["spec"]["target"].update(creationPolicy="Owner"))


# rule 1
add("bad-generator-periodic", "generator-not-createdonce", lambda w: w["src-auth"]["spec"].update(refreshPolicy="Periodic"))
add("bad-generator-no-refreshpolicy", "generator-not-createdonce", lambda w: w["grafana"]["spec"].pop("refreshPolicy"))
# rule 2
add("bad-source-owner", "source-not-orphan", lambda w: w["src-db"]["spec"]["target"].update(creationPolicy="Owner"))
add("bad-source-no-class", "source-without-class", lambda w: w["src-auth"]["metadata"].pop("annotations"))
# rule 3
add("bad-role-empty-resourcenames", "role-resourcenames-empty", lambda w: w["role-auth"]["rules"][0].update(resourceNames=[]))
add("bad-role-no-resourcenames", "role-resourcenames-empty", lambda w: w["role-db"]["rules"][0].pop("resourceNames"))
add("bad-role-no-sentinel", "role-no-sentinel", lambda w: w["role-auth"]["rules"][0].update(resourceNames=["oidc-app"]))
add("bad-role-verb-list", "role-verbs", lambda w: w["role-auth"]["rules"][0].update(verbs=["get", "list"]))
add("bad-role-verb-wildcard", "role-verbs", lambda w: w["role-db"]["rules"][0].update(verbs=["*"]))
add("bad-role-resource-wildcard", "role-resources", lambda w: w["role-auth"]["rules"][0].update(resources=["*"]))
add("bad-role-name-outside-convention", "role-name-not-allowed", lambda w: w["role-auth"]["rules"][0]["resourceNames"].append("authentik-core-secrets"))
add("bad-role-pg-name-in-auth", "role-name-not-allowed", lambda w: w["role-auth"]["rules"][0]["resourceNames"].append("pg-app"))
add("bad-role-second-rule-list", "role-verbs", lambda w: w["role-auth"]["rules"].append(
    {"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"], "resourceNames": ["eso-k8s-sentinel-none"]}))
add("bad-reader-clusterrolebinding", "reader-bound-cluster-wide", lambda w: w.update({"rb-auth": binding("k8s-auth", "auth", "ClusterRoleBinding", "ClusterRole")}))
add("bad-store-without-role", "store-without-role", lambda w: [w.pop("role-db"), w.pop("rb-db"), w.pop("copy-db")])
add("bad-store-wrong-namespace", "store-namespace", lambda w: w["store-db"]["spec"]["provider"]["kubernetes"].update(remoteNamespace="auth"))
# rule 4
add("bad-key-not-in-role", "key-not-in-role", lambda w: w["copy-auth"]["spec"]["data"][0]["remoteRef"].update(key="oidc-other"))
add("bad-key-without-source", "key-without-source", lambda w: w.pop("src-db"))
# rule 5
add("bad-t6-encryption-key", "generator-t6-key", lambda w: w["src-auth"]["spec"]["target"]["template"]["data"].update(SPARKY_API_ENCRYPTION_KEY="x"))
add("bad-t6-key-base", "generator-t6-key", lambda w: w.update(sure=source("sure-secret", "sure", "T4", "SECRET_KEY_BASE")))
add("bad-t6-secret-key-lower", "generator-t6-key", lambda w: w.update(poly=source("polyfin", "polyfin", "T3", "secret-key")))
add("bad-t6-restic", "generator-t6-key", lambda w: w.update(r=source("restic", "backup", "T3", "RESTIC_PASSWORD")))
add("bad-t6-t4-without-justification", "generator-t6-key", lambda w: w.update(sess=_t4(False)))
add("bad-t6-justification-wrong-class", "generator-t6-key", lambda w: w.update(
    sess=dict(_t4(True), metadata={"name": "x", "namespace": "x", "annotations": {"kube-ops.io/secret-class": "T3", "kube-ops.io/not-data-key": "why"}})))

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "manifest.tsv"), "w") as m:
    for name, code, w in fixtures:
        with open(os.path.join(out, name + ".jsonl"), "w") as fh:
            for d in w.values():
                fh.write(json.dumps(d) + "\n")
        m.write("%s\t%s\n" % (name, code or "-"))
PYEOF

python3 -I "$tmp/fixtures.py" "$tmp/fx"
npass=0 nfail=0
while IFS=$'\t' read -r name code; do
  rc=0
  python3 -I "$tmp/analyze.py" --require-stores "$tmp/fx/$name.jsonl" >"$tmp/res.txt" 2>&1 || rc=$?
  if [ "$code" = "-" ]; then
    if [ "$rc" != 0 ]; then echo "SELF-TEST FAIL: compliant fixture $name refused:" >&2; cat "$tmp/res.txt" >&2; exit 1; fi
    npass=$((npass + 1))
  else
    if [ "$rc" = 0 ]; then echo "SELF-TEST FAIL: negative fixture $name accepted (expected $code)" >&2; exit 1; fi
    if ! grep -q "VIOLATION $code " "$tmp/res.txt"; then echo "SELF-TEST FAIL: fixture $name refused for the wrong reason (expected $code):" >&2; cat "$tmp/res.txt" >&2; exit 1; fi
    nfail=$((nfail + 1))
  fi
done < "$tmp/fx/manifest.tsv"

# ---------------------------------------------------------------------------------------------
# Real tree: rendered roots (shared render cache, as scripts/policy-check.sh).
# ---------------------------------------------------------------------------------------------
roots=()
while IFS= read -r r; do roots+=("$r"); done < <(awk '/^roots=\(/{f=1;next} f&&/^\)/{exit} f{print $1}' scripts/check-v1-active-contract.sh)
[ "${#roots[@]}" -gt 0 ] || { echo "ERROR: no roots found in scripts/check-v1-active-contract.sh" >&2; exit 1; }
bash scripts/lib/render-cache.sh prerender "${roots[@]}" >/dev/null 2>"$tmp/prerender.err" || { cat "$tmp/prerender.err" >&2; echo "ERROR: render failed" >&2; exit 1; }
: > "$tmp/real.jsonl"
for root in "${roots[@]}"; do
  f="$(bash scripts/lib/render-cache.sh render "$root")" || { echo "ERROR: render failed for $root" >&2; exit 1; }
  yq -o=json -I=0 'select(.kind == "ExternalSecret" or .kind == "ClusterSecretStore" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRoleBinding")' "$f" >> "$tmp/real.jsonl"
done
if ! python3 -I "$tmp/analyze.py" --require-stores "$tmp/real.jsonl" > "$tmp/real.txt" 2>&1; then
  cat "$tmp/real.txt" >&2
  echo "ESO_GENERATED_SECRETS_CONTRACT=FAIL" >&2
  exit 1
fi
echo "ESO_GENERATED_SECRETS_CONTRACT=PASS (self-test ok: $npass compliant, $nfail negative fixtures; ${#roots[@]} rendered roots)"
