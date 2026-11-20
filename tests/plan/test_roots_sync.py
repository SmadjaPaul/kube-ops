"""Garde de derive : chaque chemin Argo existant doit figurer dans scripts/plan/roots.txt.

Sources Argo lues : `directories` des ApplicationSets de k8s/bootstrap/argocd-root et
`spec.source.path` des Applications de k8s/clusters/oracle-a1/apps. Un chemin absent du
depot est signale, pas en erreur.
"""
import glob
import os
import unittest

import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def argo_paths():
    paths = set()
    for f in glob.glob(os.path.join(REPO, "k8s", "bootstrap", "argocd-root", "*applicationset*.yaml")):
        with open(f) as fh:
            for doc in yaml.safe_load_all(fh):
                if not isinstance(doc, dict) or doc.get("kind") != "ApplicationSet":
                    continue
                for gen in (doc.get("spec") or {}).get("generators", []):
                    for d in (gen.get("git") or {}).get("directories", []) or []:
                        paths.add(d["path"])
    for f in glob.glob(os.path.join(REPO, "k8s", "clusters", "oracle-a1", "apps", "*.yaml")):
        with open(f) as fh:
            for doc in yaml.safe_load_all(fh):
                if isinstance(doc, dict) and doc.get("kind") == "Application":
                    p = ((doc.get("spec") or {}).get("source") or {}).get("path")
                    if p:
                        paths.add(p)
    return paths


def roots():
    out = set()
    with open(os.path.join(REPO, "scripts", "plan", "roots.txt")) as fh:
        for line in fh:
            s = line.strip()
            if s and not s.startswith("#"):
                out.add(s)
    return out


class RootsSync(unittest.TestCase):
    def test_every_existing_argo_path_is_rendered(self):
        missing = sorted(p for p in argo_paths()
                         if os.path.isdir(os.path.join(REPO, p)) and p not in roots())
        self.assertEqual(missing, [], f"chemins Argo non rendus par le plan : {missing}")

    def test_argo_paths_are_discovered(self):
        # Garde-fou sur le lecteur lui-meme : au moins les AppSets applications et infrastructure.
        self.assertIn("k8s/applications/media", argo_paths())
        self.assertIn("k8s/infrastructure/controllers", argo_paths())
        self.assertIn("k8s/clusters/oracle-a1/cnpg-cluster", argo_paths())


if __name__ == "__main__":
    unittest.main()
