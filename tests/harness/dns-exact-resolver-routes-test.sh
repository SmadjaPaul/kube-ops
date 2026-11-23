#!/usr/bin/env bash
# PLT-149 lifecycle guard: the exact-name list of dns-exact-resolver must cover every
# HTTPRoute attached to gateway/internal that is actually deployed (k8s/applications,
# k8s/infrastructure), minus the documented exclusions, and must not list a name that
# no manifest references. Fails when a new internal route is added without the name
# being added to the resolver Corefile (otherwise AAAA/HTTPS public records leak).
# Static only: no cluster, no network.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -I - "$repo_root" <<'PY'
import glob, os, re, sys
import yaml

root = sys.argv[1]
# tv.smadja.dev: Cloudflare-only by decision (PLT-149). smadja.dev: apex, never listed.
EXCLUDED = {"tv.smadja.dev", "smadja.dev"}
cm = open(f"{root}/k8s/infrastructure/network/dns-exact-resolver/configmap.yaml").read()
m = re.search(r'template IN A smadja\.dev \{\s*match "\^\(([^)]*)\)\[\.\]\$"', cm)
names = {n.replace("[.]", ".") for n in m.group(1).split("|")}

routes = {}
for sub in ("applications", "infrastructure"):
    for f in glob.glob(f"{root}/k8s/{sub}/**/*.y*ml", recursive=True):
        base = os.path.basename(f)
        if ".dormant." in base or ".staged." in base:
            continue
        try:
            docs = list(yaml.safe_load_all(open(f)))
        except Exception:
            continue
        for d in docs:
            if not isinstance(d, dict) or d.get("kind") != "HTTPRoute":
                continue
            spec = d.get("spec") or {}
            if any(p.get("name") == "internal" for p in spec.get("parentRefs", [])):
                for h in spec.get("hostnames", []):
                    routes.setdefault(h, os.path.relpath(f, root))

bad = []
for h, f in sorted(routes.items()):
    if h not in names and h not in EXCLUDED:
        bad.append(f"{h} ({f}): HTTPRoute gateway/internal missing from the dns-exact-resolver list")
corpus = ""
for f in glob.glob(f"{root}/k8s/**/*.y*ml", recursive=True):
    if f.endswith("dns-exact-resolver/configmap.yaml"):
        continue
    corpus += open(f, errors="ignore").read()
for n in sorted(names):
    if n not in corpus:
        bad.append(f"{n}: listed in the resolver but referenced by no manifest (stale)")
if bad:
    print("DNS_EXACT_RESOLVER_ROUTES_TEST=FAIL")
    print("\n".join(bad))
    sys.exit(1)
print(f"DNS_EXACT_RESOLVER_ROUTES_TEST=PASS routes={len(routes)} names={len(names)}")
PY
