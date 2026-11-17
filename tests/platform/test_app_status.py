#!/usr/bin/env python3
"""Tests hors cluster de scripts/app-status.sh et du schema docs/contracts/app-status-v1.schema.json.

Niveau de preuve : STATIC (fixtures + faux kubectl-ro). Executable en local et en CI :
  python3 -m unittest discover -s tests/platform -p 'test_*.py'
Chaque fixture tests/platform/fixtures/app-status/<cas>/ decrit un etat du cluster ; la sortie du script doit
valider le schema, porter le statut et le code de sortie attendus, et ne contenir aucun secret.
"""
import json
import os
import pathlib
import re
import subprocess
import unittest

import jsonschema

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / "tests" / "platform" / "fixtures" / "app-status"
SCRIPT = ROOT / "scripts" / "app-status.sh"
SCHEMA = json.loads((ROOT / "docs" / "contracts" / "app-status-v1.schema.json").read_text(encoding="utf-8"))
COMMIT = "a" * 40
NOW = "2026-11-17T12:00:00Z"
SECRET_PATTERNS = re.compile(r"(token|password|secret|bearer|BEGIN [A-Z ]*PRIVATE KEY)", re.I)


def run(case, app="demo-web", extra=None):
    env = dict(
        os.environ,
        APP_STATUS_KUBECTL=f"bash {FIX / 'kubectl-stub.sh'}",
        APP_STATUS_FIXTURE=str(FIX / case),
        APP_STATUS_APP_YAML=str(FIX / "app.yaml"),
        APP_STATUS_NOW=NOW,
    )
    proc = subprocess.run(
        ["bash", str(SCRIPT), app, "--commit", COMMIT] + (extra or []),
        capture_output=True, text=True, env=env, timeout=60,
    )
    return proc


class AppStatusFixtures(unittest.TestCase):
    def test_each_fixture(self):
        cases = sorted(p.name for p in FIX.iterdir() if (p / "expect.json").exists())
        self.assertGreaterEqual(len(cases), 5)
        for case in cases:
            with self.subTest(case=case):
                expect = json.loads((FIX / case / "expect.json").read_text(encoding="utf-8"))
                proc = run(case)
                self.assertEqual(proc.returncode, expect["exit"], proc.stderr)
                doc = json.loads(proc.stdout)
                jsonschema.Draft202012Validator(SCHEMA, format_checker=jsonschema.FormatChecker()).validate(doc)
                self.assertEqual(doc["status"], expect["status"])
                self.assertEqual(doc["timestamp"], NOW)
                if expect["reasonContains"]:
                    self.assertIn(expect["reasonContains"], doc["reason"])
                else:
                    self.assertNotIn("reason", doc)
                self.assertIsNone(SECRET_PATTERNS.search(json.dumps(doc)), "motif de secret dans la sortie")

    def test_pass_document(self):
        doc = json.loads(run("pass").stdout)
        self.assertEqual(doc["requested"]["commit"], COMMIT)
        self.assertEqual(doc["synced"]["revision"], COMMIT)
        self.assertEqual(doc["argo"], {"application": "gen-demo-web", "sync": "Synced", "health": "Healthy", "operationPhase": "Succeeded"})
        self.assertEqual(doc["workloads"]["pods"], {"ready": 2, "total": 2})
        self.assertEqual(doc["smoke"]["result"], "pass")
        self.assertEqual(doc["smoke"]["target"], "demo-web:80/healthz")
        self.assertEqual(doc["evidenceLevel"], "RUNTIME")
        self.assertEqual({c["name"]: c["result"] for c in doc["checks"]}, {"db": "not_applicable", "backup": "not_applicable", "restore": "not_applicable"})

    def test_cluster_unreadable_is_static(self):
        doc = json.loads(run("cluster-unreadable").stdout)
        self.assertEqual(doc["evidenceLevel"], "STATIC")
        self.assertEqual(doc["argo"]["sync"], "Unknown")

    def test_usage_errors(self):
        for args in ([], ["Bad_Name"], ["demo-web", "--cluster", "nope"], ["demo-web", "--commit", "zz"]):
            with self.subTest(args=args):
                proc = subprocess.run(["bash", str(SCRIPT)] + args, capture_output=True, text=True, timeout=30)
                self.assertEqual(proc.returncode, 2)
                self.assertEqual(proc.stdout, "")


class AppStatusSchema(unittest.TestCase):
    def validator(self):
        return jsonschema.Draft202012Validator(SCHEMA, format_checker=jsonschema.FormatChecker())

    def base(self):
        return json.loads(run("pass").stdout)

    def test_example_is_valid(self):
        self.validator().validate(json.loads((ROOT / "docs/contracts/app-status-v1.example.json").read_text(encoding="utf-8")))

    def test_fail_requires_reason(self):
        doc = self.base()
        doc["status"] = "FAIL"
        self.assertFalse(self.validator().is_valid(doc))
        doc["reason"] = "x"
        self.assertTrue(self.validator().is_valid(doc))

    def test_pass_requires_runtime_and_smoke(self):
        for mutate in (
            lambda d: d.update(evidenceLevel="STATIC"),
            lambda d: d["smoke"].update(result="unavailable"),
            lambda d: d["argo"].update(sync="OutOfSync"),
            lambda d: d["synced"].update(revision=None),
        ):
            doc = self.base()
            mutate(doc)
            self.assertFalse(self.validator().is_valid(doc))

    def test_no_additional_properties(self):
        doc = self.base()
        doc["token"] = "x"
        self.assertFalse(self.validator().is_valid(doc))


if __name__ == "__main__":
    unittest.main()
