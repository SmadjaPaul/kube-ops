#!/usr/bin/env python3
"""Test HORS Backstage du template golden-paths/platform-application.

- valide les parametres d'exemple contre les parametres du template (comme le formulaire) ;
- rend le skeleton avec nunjucks (moteur Backstage nunjitsu 0.6.2, cf. tests/platform/template) ;
- verifie que app.yaml est accepte par le chart (helm), que le catalog-info est identique
  au generateur de reference, et que seuls deux fichiers sont produits.
Niveau de preuve : STATIC/INTEGRATION-LOCAL (pas d'appel reel au scaffolder ni a GitHub).
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from catalog_info import render_catalog_info  # noqa: E402
from test_contract import helm_template  # noqa: E402

ROOT = HERE.parents[1]
TEMPLATE = ROOT / "golden-paths" / "platform-application" / "template.yaml"
SKELETON = ROOT / "golden-paths" / "platform-application" / "skeleton"
PARAMS = HERE / "fixtures" / "template-params.json"
NODE_DIR = HERE / "template"
NODE = shutil.which("node")

try:
    import jsonschema  # noqa: E402
except ImportError:  # pragma: no cover
    jsonschema = None


def template_schema(tpl):
    """Fusionne les pages de parametres en un schema, comme le formulaire Backstage."""
    schema = {"type": "object", "properties": {}, "required": [], "allOf": []}
    for page in tpl["spec"]["parameters"]:
        schema["properties"].update(page.get("properties", {}))
        schema["required"].extend(page.get("required", []))
        schema["allOf"].extend(page.get("allOf", []))
    schema["required"] = sorted(set(schema["required"]))
    if not schema["allOf"]:
        del schema["allOf"]
    return schema


class TemplateHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tpl = yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))
        cls.params = json.loads(PARAMS.read_text(encoding="utf-8"))
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix="platform-template-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def render(self, params, label="ok"):
        work = self.tmp / label
        work.mkdir(parents=True, exist_ok=True)
        tpl_json = work / "template.json"
        tpl_json.write_text(json.dumps(self.tpl), encoding="utf-8")
        params_json = work / "params.json"
        params_json.write_text(json.dumps(params), encoding="utf-8")
        out = work / "out"
        proc = subprocess.run(
            [NODE, "render.mjs", str(tpl_json), str(params_json), str(SKELETON), str(out)],
            cwd=NODE_DIR, capture_output=True, text=True,
        )
        return proc, out

    @unittest.skipIf(NODE is None, "node absent")
    def test_parameters_accept_example_and_reject_bad_values(self):
        if jsonschema is None:
            self.skipTest("jsonschema absent (pip install jsonschema)")
        schema = template_schema(self.tpl)
        jsonschema.validate(self.params, schema)
        bad = dict(self.params, size="xl")
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(bad, schema)
        bad_digest = dict(self.params, image="ghcr.io/example/demo-web:1.0.0")
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(bad_digest, schema)

    @unittest.skipIf(NODE is None, "node absent")
    def test_skeleton_renders_exactly_two_files_and_chart_accepts_app(self):
        proc, out = self.render(self.params)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        files = sorted(str(p.relative_to(out)) for p in out.rglob("*") if p.is_file())
        self.assertEqual(files, [
            "k8s/apps-generated/demo-web/app.yaml",
            "k8s/apps-generated/demo-web/catalog-info.yaml",
        ])
        app_text = (out / "k8s/apps-generated/demo-web/app.yaml").read_text(encoding="utf-8")
        app = yaml.safe_load(app_text)
        self.assertEqual(app["spec"]["source"]["image"], self.params["image"])
        self.assertEqual(app["spec"]["runtime"]["replicas"], 2)
        self.assertIs(app["spec"]["observability"]["metrics"], True)
        code, _out, err = helm_template(app)
        self.assertEqual(code, 0, err)

    @unittest.skipIf(NODE is None, "node absent")
    def test_catalog_info_matches_reference_generator(self):
        proc, out = self.render(self.params, label="parity")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        app = yaml.safe_load((out / "k8s/apps-generated/demo-web/app.yaml").read_text(encoding="utf-8"))
        rendered = (out / "k8s/apps-generated/demo-web/catalog-info.yaml").read_text(encoding="utf-8")
        self.assertEqual(rendered, render_catalog_info(app))

    @unittest.skipIf(NODE is None, "node absent")
    def test_rendering_is_deterministic(self):
        a, out_a = self.render(self.params, label="det-a")
        b, out_b = self.render(self.params, label="det-b")
        self.assertEqual(a.returncode + b.returncode, 0)
        for rel in ["k8s/apps-generated/demo-web/app.yaml", "k8s/apps-generated/demo-web/catalog-info.yaml"]:
            self.assertEqual((out_a / rel).read_bytes(), (out_b / rel).read_bytes())


if __name__ == "__main__":
    unittest.main()
