#!/usr/bin/env python3
"""Rapport CI : rend chaque app de k8s/apps-generated et chaque fixture, ecrit l'artefact JSON
platform-app-render.v1 et un resume Markdown (GITHUB_STEP_SUMMARY).

Usage : render_report.py <sortie.json>   (le Markdown part sur stdout)
"""
import hashlib
import json
import pathlib
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from test_contract import helm_template  # noqa: E402

ROOT = HERE.parents[1]
APPS = ROOT / "k8s" / "apps-generated"
FIXTURES = HERE / "fixtures"


def resources_of(rendered: str):
    docs = [d for d in yaml.safe_load_all(rendered) if d]
    return [f"{d['kind']}/{d['metadata'].get('name')}" for d in docs], docs


def entry(source: pathlib.Path, label: str):
    doc = yaml.safe_load(source.read_text(encoding="utf-8"))
    code, out, err = helm_template(doc)
    rec = {
        "source": str(source.relative_to(ROOT)),
        "kind": label,
        "name": doc.get("metadata", {}).get("name"),
        "accepted": code == 0,
        "resources": [],
        "renderSha256": None,
        "violations": [],
    }
    if code == 0:
        rec["resources"], _ = resources_of(out)
        rec["renderSha256"] = hashlib.sha256(out.encode("utf-8")).hexdigest()
    else:
        rec["violations"] = [line.strip() for line in err.splitlines() if line.strip()][-3:]
    return rec


def main():
    records = [entry(p, "app") for p in sorted(APPS.glob("*/app.yaml"))]
    records += [entry(p, "fixture") for p in sorted(FIXTURES.glob("*.yaml"))]
    report = {
        "schema": "platform-app-render.v1",
        "contract": "platform.smadja.dev/v1",
        "renderer": "platform-app-0.1.0",
        "items": records,
    }
    pathlib.Path(sys.argv[1]).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = ["## platform-app render (contrat v1)", "", "| Source | Kind | Accepte | Ressources | Violations |", "|---|---|---|---|---|"]
    for r in records:
        viol = "<br>".join(r["violations"]).replace("|", "/") if r["violations"] else ""
        lines.append(f"| `{r['source']}` | {r['kind']} | {'oui' if r['accepted'] else 'non'} | {len(r['resources'])} | {viol} |")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
