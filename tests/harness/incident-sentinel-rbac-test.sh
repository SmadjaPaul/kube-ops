#!/usr/bin/env bash
# PLT-455 : le ClusterRole incident-sentinel-read n'a aucun verbe d'écriture, aucun accès `secrets`,
# aucun wildcard sur le groupe core, et le scale set sentinelle est le seul à monter le jeton du SA.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="$repo_root/k8s/optional/github-actions-arc-agent-harness"
python3 - "$dir/incident-sentinel-rbac.yaml" "$dir/runner-application-sentinel.yaml" "$dir/runner-application-agents.yaml" <<'PY'
import sys, yaml
rbac, sent, agents = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(rbac)) if d]
role = next(d for d in docs if d["kind"] == "ClusterRole")
ok = {"get", "list", "watch"}
for r in role["rules"]:
    assert set(r["verbs"]) <= ok, f"verbe interdit : {r['verbs']}"
    res = set(r["resources"])
    assert not any(x in ("secrets", "secrets/*", "configmaps") or x.startswith("pods/exec") or x in ("pods/attach", "pods/portforward", "serviceaccounts/token") for x in res), f"ressource interdite : {res}"
    if "" in r["apiGroups"]:
        assert "*" not in res, "wildcard sur le groupe core"
    assert "*" not in r["apiGroups"], "apiGroups wildcard"
for d in docs:
    assert d["kind"] != "Role" or False
sa = yaml.safe_load(open(sent))["spec"]["source"]["helm"]["valuesObject"]["template"]["spec"]
assert sa["serviceAccountName"] == "incident-sentinel" and sa["automountServiceAccountToken"] is True
ag = yaml.safe_load(open(agents))["spec"]["source"]["helm"]["valuesObject"]["template"]["spec"]
assert ag["automountServiceAccountToken"] is False, "le scale set pr-triage ne doit pas monter de jeton"
assert "incident-sentinel" not in open(agents).read().lower().replace("incident-sentinel-key", "")
print("incident-sentinel-rbac OK")
PY
