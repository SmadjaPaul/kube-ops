"""Tests du plan statique (scripts/plan/plan_diff.py) sur des rendus synthetiques.

Pas de kustomize ici : les dossiers base/head sont ecrits dans un tmp. Lancer :
  python3 -m unittest discover -s tests/plan -p 'test_*.py'
"""
import os
import shutil
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts", "plan"))
import plan_diff  # noqa: E402

SYNC = "argocd.argoproj.io/sync-options"


def pvc(name, ns="app", sc="longhorn-fast", sync=None, size="1Gi"):
    md = {"name": name, "namespace": ns}
    if sync is not None:
        md["annotations"] = {SYNC: sync}
    return {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": md,
            "spec": {"storageClassName": sc, "accessModes": ["ReadWriteOnce"],
                     "resources": {"requests": {"storage": size}}}}


def cluster(name, ns="app", sync=None, size="5Gi"):
    md = {"name": name, "namespace": ns}
    if sync is not None:
        md["annotations"] = {SYNC: sync}
    return {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": md,
            "spec": {"instances": 1, "storage": {"size": size, "storageClass": "longhorn-fast"}}}


def namespace(name, sync=None):
    md = {"name": name}
    if sync is not None:
        md["annotations"] = {SYNC: sync}
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": md}


def deployment(name, image, ns="app"):
    return {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": name, "namespace": ns},
            "spec": {"template": {"spec": {"containers": [{"name": name, "image": image}]}}}}


def storageclass(name, reclaim):
    return {"apiVersion": "storage.k8s.io/v1", "kind": "StorageClass", "metadata": {"name": name},
            "provisioner": "x", "reclaimPolicy": reclaim}


def secret(name, keys, ns="app"):
    return {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name, "namespace": ns},
            "data": {k: "c2VjcmV0" for k in keys}}


class PlanCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="plan-test-")
        self.base_objs, self.head_objs = [], []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, side, root, objs):
        d = os.path.join(self.tmp, side)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, root + ".yaml"), "w") as fh:
            yaml.safe_dump_all(objs, fh)

    def run_plan(self, base, head, root="k8s__applications__app"):
        self._write("base", root, base + [storageclass("longhorn-fast", "Retain"),
                                          storageclass("oci-bv", "Delete")])
        self._write("head", root, head + [storageclass("longhorn-fast", "Retain"),
                                          storageclass("oci-bv", "Delete")])
        return plan_diff.diff(plan_diff.load_dir(os.path.join(self.tmp, "base")),
                              plan_diff.load_dir(os.path.join(self.tmp, "head")))

    def classes(self, res):
        return {(c["kind"], c["name"]): (c["class"], c["destructive"]) for c in res["changes"]}


class StatelessAndAnnotations(PlanCase):
    def test_stateless_change_passes(self):
        res = self.run_plan([deployment("web", "app:1")], [deployment("web", "app:2")])
        self.assertEqual(res["status"], "PASS")
        self.assertEqual(res["counts"], {"+": 0, "~": 1, "-": 0})

    def test_annotation_only_on_pvc_passes_and_is_not_destructive(self):
        res = self.run_plan([pvc("data")], [pvc("data", sync="Prune=false,Delete=false")])
        self.assertEqual(res["status"], "PASS")
        self.assertFalse(any(c["destructive"] for c in res["changes"]))

    def test_upgrade_prune_only_to_both_passes(self):
        res = self.run_plan([pvc("data", sync="Prune=false")],
                            [pvc("data", sync="Prune=false,Delete=false")])
        self.assertEqual(res["status"], "PASS")


class RemovedObjects(PlanCase):
    def test_removed_retain_pvc_unprotected_blocks_class_b(self):
        # Equivalent de b9a307f7 : PVC retire, SC Retain, sans Prune=false.
        res = self.run_plan([pvc("config", sc="longhorn-fast")], [])
        self.assertEqual(res["status"], "BLOCK")
        self.assertEqual(self.classes(res)[("PersistentVolumeClaim", "config")], ("B", True))

    def test_removed_pvc_with_delete_only_blocks(self):
        # Equivalent de e63fc72e : Delete=false ne protege pas du retrait Git.
        res = self.run_plan([pvc("retired-pilot-data", sync="Delete=false")], [])
        self.assertEqual(res["status"], "BLOCK")
        self.assertTrue(any(c["destructive"] for c in res["changes"]))

    def test_removed_pvc_with_prune_false_is_orphan_and_passes(self):
        res = self.run_plan([pvc("data", sync="Prune=false,Delete=false")], [])
        self.assertEqual(res["status"], "PASS")
        self.assertFalse(any(c["destructive"] for c in res["changes"]))

    def test_removed_pvc_with_delete_reclaim_is_class_c(self):
        res = self.run_plan([pvc("oci", sc="oci-bv")], [])
        self.assertEqual(self.classes(res)[("PersistentVolumeClaim", "oci")], ("C", True))
        self.assertEqual(res["status"], "BLOCK")

    def test_removed_pvc_with_unknown_storageclass_fails_closed(self):
        res = self.run_plan([pvc("x", sc="inconnue")], [])
        self.assertEqual(self.classes(res)[("PersistentVolumeClaim", "x")], ("C", True))
        self.assertEqual(res["status"], "BLOCK")

    def test_removed_cnpg_cluster_unprotected_is_class_c(self):
        res = self.run_plan([cluster("pg")], [])
        self.assertEqual(self.classes(res)[("Cluster", "pg")], ("C", True))
        self.assertEqual(res["status"], "BLOCK")

    def test_removed_cnpg_cluster_with_prune_false_passes(self):
        res = self.run_plan([cluster("pg", sync="Prune=false,Delete=false")], [])
        self.assertEqual(res["status"], "PASS")

    def test_removed_namespace_with_pvc_is_cascade_class_c(self):
        res = self.run_plan([namespace("app"), pvc("data", ns="app", sync="Prune=false,Delete=false")], [])
        self.assertEqual(self.classes(res)[("Namespace", "app")], ("C", True))
        self.assertEqual(res["status"], "BLOCK")

    def test_removed_namespace_without_state_passes(self):
        res = self.run_plan([namespace("tools")], [])
        self.assertEqual(self.classes(res)[("Namespace", "tools")], ("A", False))
        self.assertEqual(res["status"], "PASS")

    def test_removed_generated_secret_is_class_c(self):
        res = self.run_plan([secret("ca", ["tls.crt"])], [])
        self.assertEqual(self.classes(res)[("Secret", "ca")], ("C", True))
        self.assertEqual(res["status"], "BLOCK")


class ClusterIsolation(PlanCase):
    def test_same_name_on_other_cluster_does_not_hide_a_removal(self):
        # Un PVC retire d'oracle-a1 reste detecte meme si le meme nom existe encore sur homelab.
        base_h = "k8s__applications__app"
        base_o = "k8s__clusters__oracle-a1__media"
        self._write("base", base_h, [pvc("data", sync="Prune=false,Delete=false")])
        self._write("base", base_o, [pvc("data", sc="longhorn-fast")])
        self._write("head", base_h, [pvc("data", sync="Prune=false,Delete=false")])
        self._write("head", base_o, [])
        res = plan_diff.diff(plan_diff.load_dir(os.path.join(self.tmp, "base")),
                             plan_diff.load_dir(os.path.join(self.tmp, "head")))
        removed = [c for c in res["changes"] if c["op"] == "-"]
        self.assertEqual([c["cluster"] for c in removed], ["oracle-a1"])
        self.assertEqual(res["status"], "BLOCK")


class NewAndChangedObjects(PlanCase):
    def test_added_pvc_without_prune_false_blocks(self):
        res = self.run_plan([], [pvc("new")])
        self.assertEqual(res["status"], "BLOCK")
        self.assertEqual(res["violations"][0]["code"], "STATEFUL_UNPROTECTED_NEW")

    def test_added_pvc_with_both_options_passes(self):
        res = self.run_plan([], [pvc("new", sync="Prune=false,Delete=false")])
        self.assertEqual(res["status"], "PASS")

    def test_prune_false_removed_from_stateful_blocks(self):
        res = self.run_plan([pvc("data", sync="Prune=false,Delete=false")], [pvc("data")])
        self.assertEqual(res["status"], "BLOCK")
        self.assertIn("PRUNE_FALSE_REMOVED", [v["code"] for v in res["violations"]])

    def test_storageclass_change_is_immutable_and_blocks(self):
        res = self.run_plan([pvc("data", sc="longhorn-fast", sync="Prune=false,Delete=false")],
                            [pvc("data", sc="oci-bv", sync="Prune=false,Delete=false")])
        self.assertEqual(self.classes(res)[("PersistentVolumeClaim", "data")], ("IMM", True))
        self.assertEqual(res["status"], "BLOCK")

    def test_pvc_shrink_is_immutable_and_blocks(self):
        res = self.run_plan([pvc("data", size="10Gi", sync="Prune=false,Delete=false")],
                            [pvc("data", size="5Gi", sync="Prune=false,Delete=false")])
        self.assertEqual(res["status"], "BLOCK")

    def test_pre_existing_unprotected_pvc_warns_but_passes(self):
        res = self.run_plan([pvc("data")], [pvc("data")])
        self.assertEqual(res["status"], "PASS")
        self.assertIn("STATEFUL_UNPROTECTED_PRE_EXISTING", [w["code"] for w in res["warnings"]])

    def test_secret_value_change_is_not_a_change(self):
        a = secret("tok", ["token"])
        b = secret("tok", ["token"])
        b["data"]["token"] = "ZGlmZmVyZW50"
        res = self.run_plan([a], [b])
        self.assertEqual(res["status"], "PASS")
        self.assertEqual(res["counts"]["~"], 0)

    def test_secret_key_set_change_is_reported(self):
        res = self.run_plan([secret("tok", ["token"])], [secret("tok", ["token", "other"])])
        self.assertEqual(self.classes(res)[("Secret", "tok")], ("C", False))
        self.assertEqual(res["status"], "PASS")


if __name__ == "__main__":
    unittest.main()
