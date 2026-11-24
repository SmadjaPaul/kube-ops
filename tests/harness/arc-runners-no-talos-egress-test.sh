#!/usr/bin/env bash
# PLT-462: ARC runners must never reach the Talos API (TCP 50000) nor the node
# (toEntities host) except Home Assistant on 8123. ARC runs on the single node
# it would reconfigure, so a Talos apply from ARC is forbidden (D-2026-11-24).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$root" "${1:-}" <<'PY'
import sys, pathlib, yaml

root = pathlib.Path(sys.argv[1])
scan = pathlib.Path(sys.argv[2]) if sys.argv[2] else root / "k8s"
bad, seen = [], 0
for path in sorted(scan.rglob("*.y*ml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except Exception:
        continue
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") not in ("CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"):
            continue
        ns = (doc.get("metadata") or {}).get("namespace", "")
        if not str(ns).startswith("arc-runners"):
            continue
        seen += 1
        specs = [doc.get("spec")] + list(doc.get("specs") or [])
        for spec in filter(None, specs):
            for rule in spec.get("egress") or []:
                ports = {str(p.get("port")) for tp in rule.get("toPorts") or [] for p in tp.get("ports") or []}
                if "50000" in ports:
                    bad.append(f"{path}: egress to port 50000 (Talos API)")
                if set(rule.get("toEntities") or []) & {"host", "remote-node"} and ports != {"8123"}:
                    bad.append(f"{path}: toEntities host/remote-node outside port 8123 (ports={sorted(ports) or 'all'})")
if bad:
    print("ARC_RUNNERS_TALOS_EGRESS=FAIL")
    print("\n".join(bad))
    sys.exit(1)
if scan == root / "k8s" and seen == 0:
    print("ARC_RUNNERS_TALOS_EGRESS=FAIL (no arc-runners policy found; test is blind)")
    sys.exit(1)
print(f"ARC_RUNNERS_TALOS_EGRESS=PASS ({seen} arc-runners policies)")
PY
