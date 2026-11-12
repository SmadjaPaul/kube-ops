#!/usr/bin/env python3
"""Fail-closed GitOps tenant registry; no PII or credentials in the repository.

Staged only: operator approval, per-tenant Authentik app binding and Doppler key
are required before the generated ApplicationSet is admitted to Argo CD.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REGISTRY = ROOT / "tenants.json"
TEMPLATE = ROOT / "applicationset.template.json"
GENERATED = ROOT / "applicationset.yaml"
ID = re.compile(r"^t-[a-z0-9]{4,18}$")
MAX_TENANTS = 30


def secret_key(tenant_id: str) -> str:
    return "APP_HERMES_" + tenant_id.upper().replace("-", "_") + "_LLM_KEY"


def load_registry():
    rows = json.loads(REGISTRY.read_text())
    if not isinstance(rows, list) or len(rows) > MAX_TENANTS:
        raise ValueError("Tenant list must contain 0 to 30 entries")
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"id", "secret_key"}:
            raise ValueError("Each tenant requires only id and secret_key; never store PII")
        tenant_id = row["id"]
        if not isinstance(tenant_id, str) or not ID.fullmatch(tenant_id):
            raise ValueError("Tenant id must match t-[a-z0-9]{4,18}")
        if tenant_id in seen or row["secret_key"] != secret_key(tenant_id):
            raise ValueError("Duplicate tenant or incorrect secret reference")
        seen.add(tenant_id)
    if [r["id"] for r in rows] != sorted(seen):
        raise ValueError("Registry must be deterministically sorted")
    return rows


def rendered(rows):
    document = json.loads(TEMPLATE.read_text())
    document["spec"]["generators"][0]["list"]["elements"] = rows
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    enroll = sub.add_parser("enroll", help="Stage a reviewed tenant; never accepts credentials")
    enroll.add_argument("tenant_id")
    sub.add_parser("validate")
    args = parser.parse_args()
    rows = load_registry()
    if args.cmd == "enroll":
        if not ID.fullmatch(args.tenant_id):
            parser.error("Use an opaque id like t-a1234 (no name or email)")
        if args.tenant_id in {r["id"] for r in rows}:
            parser.error("Tenant already registered")
        if len(rows) >= MAX_TENANTS:
            parser.error("30 tenant cap reached")
        rows.append({"id": args.tenant_id, "secret_key": secret_key(args.tenant_id)})
        rows.sort(key=lambda r: r["id"])
        REGISTRY.write_text(json.dumps(rows, indent=2) + "\n")
    output = rendered(rows)
    if args.cmd == "validate":
        if not GENERATED.exists() or GENERATED.read_text() != output:
            parser.error("applicationset.yaml is stale; regenerate via enroll")
        print("Tenant registry and generated ApplicationSet are consistent")
    else:
        GENERATED.write_text(output)
        print("Staged; obtain user approval, Authentik-only app binding and ESO before admission.")


if __name__ == "__main__":
    main()
