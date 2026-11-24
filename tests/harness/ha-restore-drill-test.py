#!/usr/bin/env python3
"""PRD-76: contract of the Home Assistant restore drill, without a cluster.

- the pods rule of restore-pvc-isolation, applied the way Velero 1.18.2 does it
  (JSONPatch.ToString + evanphx json-patch, a failed `test` returns the object
  unchanged), turns the restored production pod into the read-only verifier,
  and the admission predicate (mirror of ha-restore-test-pod-guard) accepts only
  that result;
- the verifier script (embedded in the modifier) on fake /config trees;
- the drill Job script against an in-memory API (success, hostNetwork stop,
  production drift, PV reclaim policy: Velero 1.18.2 copies Retain from the
  production PV onto the drill PV, the Job patches it back to Delete under the
  mirror of ha-restore-drill-pv-guard, leftovers are reclaimed, a PV stuck in
  Retain fails fast).
"""

import copy
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODIFIER = ROOT / "k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml"
DRILL_DIR = ROOT / "k8s/infrastructure/controllers/velero-ha-restore-drill"
STS = ROOT / "k8s/applications/automation/hassio/statefulset.yaml"


# YAML is converted by the shell wrapper (yq), PyYAML is not assumed.
RULES_JSON = Path(os.environ["HA_DRILL_RULES_JSON"])
RULES_YAML = Path(os.environ["HA_DRILL_RULES_YAML"])
HA_IMAGE = os.environ["HA_DRILL_HA_IMAGE"]


def rules():
    return json.loads(RULES_JSON.read_text())["resourceModifierRules"]


def pod_rule():
    return [r for r in rules() if r["conditions"].get("groupResource") == "pods"][0]


def ha_image():
    assert HA_IMAGE.startswith("ghcr.io/home-assistant/home-assistant:") and "@sha256:" in HA_IMAGE, HA_IMAGE
    return HA_IMAGE


# --- Velero 1.18.2 JSON patch semantics -------------------------------------
def add_quotes(v):
    if v == "":
        return True, v
    if v.startswith('"') and v.endswith('"'):
        return True, v[1:-1]
    if v == "null" or v.lower() in ("true", "false") or v[:1] in "{[":
        return False, v
    try:
        float(v)
        return False, v
    except ValueError:
        return True, v


def velero_ops(patches):
    out = []
    for p in patches:
        quoted, v = add_quotes(p.get("value", ""))
        val = '"%s"' % v if quoted else v
        out.append(json.loads('{"op": "%s", "from": "%s", "path": "%s", "value": %s}'
                              % (p["operation"], p.get("from", ""), p["path"], val)))
    return out


class TestFailed(Exception):
    pass


def _walk(doc, path):
    parts = [t.replace("~1", "/").replace("~0", "~") for t in path.split("/")[1:]]
    parent = doc
    for t in parts[:-1]:
        parent = parent[int(t)] if isinstance(parent, list) else parent[t]
    return parent, parts[-1]


def _get(doc, path):
    parent, key = _walk(doc, path)
    return parent[int(key)] if isinstance(parent, list) else parent[key]


def _add(doc, path, value):
    parent, key = _walk(doc, path)
    if isinstance(parent, list):
        i = len(parent) if key == "-" else int(key)
        if i > len(parent):
            raise IndexError(path)
        parent.insert(i, value)
    else:
        parent[key] = value


def _remove(doc, path):
    parent, key = _walk(doc, path)
    return parent.pop(int(key)) if isinstance(parent, list) else parent.pop(key)


def apply_json_patch(obj, ops):
    doc = copy.deepcopy(obj)
    for op in ops:
        o = op["op"]
        if o == "test":
            try:
                cur = _get(doc, op["path"])
            except (KeyError, IndexError):
                raise TestFailed(op["path"])
            if cur != op["value"]:
                raise TestFailed(op["path"])
        elif o == "add":
            _add(doc, op["path"], op["value"])
        elif o == "replace":
            _get(doc, op["path"])
            parent, key = _walk(doc, op["path"])
            parent[int(key) if isinstance(parent, list) else key] = op["value"]
        elif o == "remove":
            _remove(doc, op["path"])
        elif o == "move":
            _add(doc, op["path"], _remove(doc, op["from"]))
        else:
            raise AssertionError("unsupported op " + o)
    return doc


def velero_apply(pod, rule):
    """JSONPatcher.Patch: ErrTestFailed -> unchanged copy; other error -> error, object created unchanged."""
    try:
        return apply_json_patch(pod, velero_ops(rule["patches"]))
    except TestFailed:
        return copy.deepcopy(pod)
    except (KeyError, IndexError):
        return copy.deepcopy(pod)


# --- mirror of the ValidatingAdmissionPolicy ha-restore-test-pod-guard-------
def guard_admits_pod(pod, image):
    s = pod["spec"]
    if any(s.get(f) for f in ("hostNetwork", "hostPID", "hostIPC")):
        return False
    ctrs = s["containers"] + s.get("initContainers", [])
    for c in ctrs:
        sc = c.get("securityContext") or {}
        if sc.get("privileged") or (sc.get("capabilities") or {}).get("add"):
            return False
        if sc.get("allowPrivilegeEscalation") is not False:
            return False
    ic = s.get("initContainers", [])
    if not (len(ic) == 1 and ic[0]["name"] == "restore-wait"
            and re.fullmatch(r"docker\.io/velero/velero:v[0-9]+\.[0-9]+\.[0-9]+", ic[0]["image"])):
        return False
    c = s["containers"]
    if not (len(c) == 1 and c[0]["name"] == "ha-restore-verify" and c[0]["image"] == image
            and c[0].get("volumeMounts") and all(m.get("readOnly") for m in c[0]["volumeMounts"])
            and "ephemeralContainers" not in s):
        return False
    v = s.get("volumes", [])
    if not (len(v) == 1 and v[0]["name"] == "data"
            and v[0].get("persistentVolumeClaim", {}).get("claimName") == "home-assistant-home-assistant-0"):
        return False
    return s.get("serviceAccountName") == "default" and s.get("automountServiceAccountToken") is False


def production_pod_after_velero_actions():
    """home-assistant-0 as Velero 1.18.2 hands it to the modifiers: PodAction (nodeName,
    priority cleared; the projected kube-api-access volume is NOT removed) then
    PodVolumeRestoreAction (restore-wait first, securityContext copied from containers[0])."""
    caps = {"capabilities": {"add": ["NET_ADMIN", "NET_RAW", "NET_BROADCAST"]}}
    sa_mount = {"name": "kube-api-access-2jqlt", "mountPath": "/var/run/secrets/kubernetes.io/serviceaccount"}
    init = lambda n: {"name": n, "image": "busybox:1.38", "volumeMounts": [{"name": "data", "mountPath": "/config"}, sa_mount]}
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": "home-assistant-0", "namespace": "home-assistant",
                     "labels": {"app.kubernetes.io/name": "home-assistant"},
                     "annotations": {"smadja.dev/config-rev": "3"}},
        "spec": {
            "hostNetwork": True, "dnsPolicy": "ClusterFirstWithHostNet",
            "serviceAccountName": "home-assistant", "serviceAccount": "home-assistant",
            "securityContext": {"fsGroupChangePolicy": "OnRootMismatch"},
            "hostname": "home-assistant-0", "subdomain": "home-assistant",
            "initContainers": [
                {"name": "restore-wait", "image": "docker.io/velero/velero:v1.18.2", "args": ["uid"],
                 "securityContext": copy.deepcopy(caps), "volumeMounts": [{"name": "data", "mountPath": "/restores/data"}]},
                init("install-openid"), init("init-ui-files"), init("volume-permissions")],
            "containers": [{"name": "home-assistant", "image": ha_image(), "securityContext": caps,
                            "volumeMounts": [{"name": "data", "mountPath": "/config"},
                                             {"name": "core-config", "mountPath": "/config/configuration.yaml"},
                                             {"name": "secrets", "mountPath": "/config/secrets.yaml"}, sa_mount]}],
            "volumes": [{"name": "openid-patch", "configMap": {"name": "x"}},
                        {"name": "core-config", "configMap": {"name": "ha-core-config"}},
                        {"name": "secrets", "secret": {"secretName": "hassio-secrets"}},
                        {"name": "data", "persistentVolumeClaim": {"claimName": "home-assistant-home-assistant-0"}},
                        {"name": "kube-api-access-2jqlt", "projected": {"sources": []}}],
        },
    }


def verifier_script(patched):
    cmd = patched["spec"]["containers"][0]["command"]
    assert cmd[:3] == ["python3", "-I", "-c"] and cmd[4] == "/config", cmd
    return cmd[3]


class ModifierTest(unittest.TestCase):
    def setUp(self):
        self.rule = pod_rule()
        self.image = ha_image()

    def test_scoped_to_production_pod(self):
        c = self.rule["conditions"]
        self.assertEqual(c["namespaces"], ["home-assistant"])
        self.assertEqual(c["resourceNameRegex"], "^home-assistant-0$")
        self.assertNotIn("remove", [p["operation"] for p in self.rule["patches"]])

    def test_neutralises_production_pod(self):
        src = production_pod_after_velero_actions()
        self.assertFalse(guard_admits_pod(src, self.image), "guard must refuse the raw pod")
        out = velero_apply(src, self.rule)
        s = out["spec"]
        self.assertTrue(guard_admits_pod(out, self.image), json.dumps(s)[:500])
        self.assertIs(s["hostNetwork"], False)
        self.assertEqual(s["dnsPolicy"], "ClusterFirst")
        self.assertEqual(s["restartPolicy"], "Never")
        self.assertEqual([c["name"] for c in s["initContainers"]], ["restore-wait"])
        self.assertEqual(s["initContainers"][0]["securityContext"]["capabilities"], {"drop": ["ALL"]})
        self.assertEqual(s["initContainers"][0]["volumeMounts"], [{"name": "data", "mountPath": "/restores/data"}])
        self.assertEqual(s["serviceAccount"], "default")
        self.assertEqual(out["metadata"]["labels"]["app.kubernetes.io/name"], "ha-restore-verify")
        self.assertNotIn("secret", json.dumps(s["volumes"]))

    def test_unexpected_shape_is_left_unchanged_and_refused(self):
        src = production_pod_after_velero_actions()
        src["spec"]["initContainers"].pop(0)  # no PodVolumeRestore -> no restore-wait
        out = velero_apply(src, self.rule)
        self.assertEqual(out, src)
        self.assertFalse(guard_admits_pod(out, self.image))
        src = production_pod_after_velero_actions()
        src["spec"]["initContainers"].append({"name": "extra", "image": "x"})
        out = velero_apply(src, self.rule)
        self.assertEqual([c["name"] for c in out["spec"]["initContainers"]], ["restore-wait"])

    def test_pvc_rule_uses_drill_class(self):
        pvc_rules = [r for r in rules() if r["conditions"].get("groupResource") == "persistentvolumeclaims"
                     and r["conditions"]["namespaces"] == ["home-assistant"]]
        self.assertEqual(len(pvc_rules), 1)
        patch = json.loads(pvc_rules[0]["mergePatches"][0]["patchData"])
        self.assertEqual(patch, {"spec": {"storageClassName": "longhorn-drill"}})

    def test_guard_image_matches_statefulset(self):
        adm = (DRILL_DIR / "admission.yaml").read_text()
        self.assertIn("'" + self.image + "'", adm)
        out = velero_apply(production_pod_after_velero_actions(), self.rule)
        self.assertEqual(out["spec"]["containers"][0]["image"], self.image)


class VerifierTest(unittest.TestCase):
    def setUp(self):
        out = velero_apply(production_pod_after_velero_actions(), pod_rule())
        self.script = verifier_script(out)
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_verifier(self):
        p = subprocess.run([sys.executable, "-I", "-c", self.script, str(self.cfg)],
                           capture_output=True, text=True, timeout=30)
        lines = p.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1, p.stdout + p.stderr)
        return p.returncode, json.loads(lines[0])

    def make_config(self, db_ok=True, music=True):
        (self.cfg / ".storage").mkdir()
        (self.cfg / ".storage/core.entity_registry").write_text("{}")
        (self.cfg / "backups").mkdir()
        (self.cfg / "backups/a.tar").write_bytes(b"x" * 10)
        (self.cfg / "scripts.yaml").write_text("maison_musique_jouer:\n  sequence: []\n" if music else "{}\n")
        db = self.cfg / "home-assistant_v2.db"
        if db_ok:
            con = sqlite3.connect(db)
            con.execute("CREATE TABLE states (state_id INTEGER, last_updated_ts FLOAT)")
            con.execute("INSERT INTO states VALUES (1, 1764000000.5)")
            con.commit()
            con.close()
        else:
            db.write_bytes(b"not a database" * 100)

    def test_pass(self):
        self.make_config()
        rc, r = self.run_verifier()
        self.assertEqual((rc, r["status"]), (0, "PASS"))
        self.assertEqual(r["db_integrity"], "ok")
        self.assertEqual(r["db_states"], 1)
        self.assertEqual(r["native_backups"], 1)
        self.assertEqual(r["maison_musique_files"], ["scripts.yaml"])
        self.assertFalse(list(self.cfg.rglob("*-journal")), "verifier must not write")

    def test_fail_corrupt_db(self):
        self.make_config(db_ok=False)
        rc, r = self.run_verifier()
        self.assertEqual((rc, r["status"]), (1, "FAIL"))
        self.assertTrue(r["db_integrity"].startswith("error:"))

    def test_fail_empty_volume(self):
        rc, r = self.run_verifier()
        self.assertEqual((rc, r["status"], r["storage_files"]), (1, "FAIL", 0))


def load_drill():
    spec = importlib.util.spec_from_file_location("drill", DRILL_DIR / "ha-restore-drill.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.POLL = 0
    return mod


class FakeKube:
    PROD = "/api/v1/namespaces/home-assistant"
    TEST = "/api/v1/namespaces/home-assistant-restore-test"

    def __init__(self, drill, scenario="pass"):
        self.d, self.scenario, self.calls = drill, scenario, []
        self.restore = None
        self.pods, self.pvcs, self.pvs = {}, {}, {}
        self.patches = []
        self.prod_restarts = 0
        self.cm = {"data": {"resource-modifier.yaml": RULES_YAML.read_text()}}

    def call(self, method, path, body=None, raw=False):
        self.calls.append((method, path))
        base = path.split("?")[0]
        if method == "GET" and base == "/api/v1/namespaces/home-assistant-restore-test":
            return {"status": {"phase": "Active"}, "metadata": {"labels": {"pod-security.kubernetes.io/enforce": "baseline"}}}
        if method == "GET" and "validatingadmissionpolic" in base:
            return {"metadata": {}}
        if method == "GET" and base.endswith("/configmaps/restore-pvc-isolation"):
            return self.cm
        if method == "GET" and base == self.PROD + "/persistentvolumeclaims/home-assistant-home-assistant-0":
            return {"metadata": {"uid": "1b4227d4"}, "spec": {"volumeName": "pvc-1b4227d4"}}
        if method == "GET" and base == self.PROD + "/pods/home-assistant-0":
            if self.restore and self.scenario == "prod-restart":
                self.prod_restarts = 1
            return {"metadata": {"uid": "a950"}, "status": {"phase": "Running",
                    "containerStatuses": [{"restartCount": self.prod_restarts}]}}
        if method == "GET" and base.endswith("/backups"):
            assert "velero.io%2Fschedule-name%3Dvelero-daily-home-assistant" in path
            return {"items": [
                {"metadata": {"name": "velero-daily-home-assistant-20261123020002"},
                 "status": {"phase": "Completed", "completionTimestamp": "2026-11-23T02:05:28Z"}},
                {"metadata": {"name": "velero-daily-home-assistant-20261124082947"},
                 "status": {"phase": "Completed", "completionTimestamp": "2026-11-24T08:49:21Z"}},
                {"metadata": {"name": "velero-daily-home-assistant-20261125023000"},
                 "status": {"phase": "InProgress"}}]}
        if method == "POST" and base.endswith("/restores"):
            assert restore_guard_admits(body), body
            self.restore = body
            pod = velero_apply(production_pod_after_velero_actions(), pod_rule())
            if self.scenario == "hostnetwork":
                pod["spec"]["hostNetwork"] = True
            pod["status"] = {"phase": "Succeeded"}
            self.pods["home-assistant-0"] = pod
            self.pvcs["home-assistant-home-assistant-0"] = {"metadata": {"name": "home-assistant-home-assistant-0"},
                                                            "spec": {"volumeName": "pvc-drill"}}
            # restore finalizer: the dynamic PV gets the production PV reclaim policy (Retain)
            self.pvs["pvc-drill"] = drill_pv("pvc-drill", "Bound")
            return body
        if method == "GET" and "/restores/" in base:
            return {"status": {"phase": "Completed", "warnings": 1}}
        if method == "GET" and base.endswith("/podvolumerestores"):
            return {"items": [{"spec": {"volume": "data"}, "status": {"phase": "Completed", "progress": {"bytesDone": 9141242}}}]}
        if method == "GET" and base == self.TEST + "/pods":
            return {"items": list(self.pods.values())}
        if method == "GET" and base == self.TEST + "/persistentvolumeclaims":
            return {"items": list(self.pvcs.values())}
        if method == "GET" and base == self.TEST + "/pods/home-assistant-0":
            return self.pods.get("home-assistant-0")
        if method == "GET" and base == self.TEST + "/pods/home-assistant-0/log":
            return 'noise\n{"status": "PASS", "db_integrity": "ok"}\n'
        if method == "DELETE" and base.startswith(self.TEST + "/pods/"):
            return self.pods.pop(base.rsplit("/", 1)[1], None)
        if method == "DELETE" and base.startswith(self.TEST + "/persistentvolumeclaims/"):
            for pv in self.pvs.values():
                pv["status"]["phase"] = "Released"
            self.reclaim()
            return self.pvcs.pop(base.rsplit("/", 1)[1], None)
        if method == "GET" and base == "/api/v1/persistentvolumes":
            return {"items": [copy.deepcopy(pv) for pv in self.pvs.values()] + [other_pv()]}
        if method == "GET" and base.startswith("/api/v1/persistentvolumes/"):
            pv = self.pvs.get(base.rsplit("/", 1)[1])
            return copy.deepcopy(pv) if pv else None
        if method == "PATCH" and base.startswith("/api/v1/persistentvolumes/"):
            name = base.rsplit("/", 1)[1]
            if self.scenario == "patch-denied":
                raise self.d.DrillError(f"PATCH {path}: HTTP 403 denied")
            old = self.pvs[name]
            new = merge_patch(old, body)
            assert pv_guard_admits(old, new), (old, new)
            self.patches.append(name)
            if self.scenario != "patch-reverted":  # Velero re-patching Retain after the Job
                self.pvs[name] = new
            self.reclaim()
            return new
        raise AssertionError(f"unexpected call {method} {path}")


    def reclaim(self):
        """PV controller + Longhorn: a Released PV in Delete disappears."""
        for n in [n for n, pv in self.pvs.items() if pv["status"]["phase"] == "Released"
                  and pv["spec"]["persistentVolumeReclaimPolicy"] == "Delete"]:
            del self.pvs[n]


def drill_pv(name, phase, policy="Retain"):
    return {"metadata": {"name": name, "labels": {"velero.io/restore-name": "x"},
                         "finalizers": ["kubernetes.io/pv-protection"]},
            "spec": {"storageClassName": "longhorn-drill", "persistentVolumeReclaimPolicy": policy,
                     "claimRef": {"namespace": "home-assistant-restore-test", "name": "home-assistant-home-assistant-0"},
                     "csi": {"driver": "driver.longhorn.io", "volumeHandle": name},
                     "capacity": {"storage": "5Gi"}, "accessModes": ["ReadWriteOnce"]},
            "status": {"phase": phase}}


def other_pv():
    pv = drill_pv("pvc-1b4227d4", "Bound")
    pv["spec"]["storageClassName"] = "longhorn-fast"
    pv["spec"]["claimRef"]["namespace"] = "home-assistant"
    return pv


def merge_patch(obj, patch):
    out = copy.deepcopy(obj)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge_patch(out[k], v)
        elif v is None:
            out.pop(k, None)
        else:
            out[k] = v
    return out


def pv_guard_admits(old, new):
    """Mirror of ha-restore-drill-pv-guard (UPDATE, no subresource)."""
    o, n = old["spec"], new["spec"]
    if not (o.get("storageClassName") == "longhorn-drill"
            and (o.get("claimRef") or {}).get("namespace") == "home-assistant-restore-test"
            and (o.get("csi") or {}).get("driver") == "driver.longhorn.io"):
        return False
    if n.get("persistentVolumeReclaimPolicy") != "Delete":
        return False
    if {k: v for k, v in n.items() if k != "persistentVolumeReclaimPolicy"} != \
            {k: v for k, v in o.items() if k != "persistentVolumeReclaimPolicy"}:
        return False
    return all(new["metadata"].get(f) == old["metadata"].get(f)
               for f in ("labels", "annotations", "finalizers", "ownerReferences"))


def restore_guard_admits(body):
    """Mirror of ha-restore-drill-restore-guard."""
    s = body["spec"]
    allowed = {"backupName", "includedNamespaces", "includedResources", "namespaceMapping",
               "restorePVs", "resourceModifier"}
    return (body["metadata"]["namespace"] == "velero"
            and re.fullmatch(r"ha-restore-drill-[0-9]{14}", body["metadata"]["name"]) is not None
            and re.fullmatch(r"velero-daily-home-assistant-[0-9]{14}", s["backupName"]) is not None
            and set(s) == allowed
            and s["includedNamespaces"] == ["home-assistant"]
            and s["includedResources"] == ["pods", "persistentvolumeclaims", "persistentvolumes"]
            and s["namespaceMapping"] == {"home-assistant": "home-assistant-restore-test"}
            and s["restorePVs"] is True
            and s["resourceModifier"] == {"kind": "ConfigMap", "name": "restore-pvc-isolation"})


class DrillJobTest(unittest.TestCase):
    def setUp(self):
        self.d = load_drill()
        self.d.LEFTOVER_SECONDS = 30

    def test_guard_text_matches_restore_body(self):
        adm = (DRILL_DIR / "admission.yaml").read_text()
        for frag in ("['pods', 'persistentvolumeclaims', 'persistentvolumes']",
                     "{'home-assistant': 'home-assistant-restore-test'}",
                     "'restore-pvc-isolation'", "^ha-restore-drill-[0-9]{14}$",
                     "system:serviceaccount:velero:ha-restore-drill"):
            self.assertIn(frag, adm)

    def test_pass_and_cleanup(self):
        k = FakeKube(self.d)
        r = self.d.run(k)
        self.assertEqual(r["status"], "PASS", r)
        self.assertEqual(r["backup"], "velero-daily-home-assistant-20261124082947")
        self.assertTrue(r["prod_unchanged"])
        self.assertEqual(r["cleanup"], {"pods": 1, "pvcs": 1, "pvs_reclaim_patched": ["pvc-drill"],
                                        "pvs_deleted": ["pvc-drill"]})
        self.assertEqual((k.pods, k.pvcs, k.pvs), ({}, {}, {}))
        self.assertNotIn("leftover_pvs_deleted", r)
        writes = [c for c in k.calls if c[0] != "GET"]
        self.assertTrue(all(p.startswith(("/apis/velero.io/v1/namespaces/velero/restores", FakeKube.TEST,
                                          "/api/v1/persistentvolumes/pvc-drill"))
                            for _, p in writes), writes)
        # the PV is switched to Delete BEFORE its PVC is deleted
        order = [c[0] + " " + c[1] for c in writes]
        self.assertLess(order.index("PATCH /api/v1/persistentvolumes/pvc-drill"),
                        [i for i, c in enumerate(order) if "/persistentvolumeclaims/" in c][0])

    def test_leftover_released_pv_is_reclaimed_first(self):
        k = FakeKube(self.d)
        k.pvs["pvc-08519a57"] = drill_pv("pvc-08519a57", "Released")
        r = self.d.run(k)
        self.assertEqual(r["status"], "PASS", r)
        self.assertEqual(r["leftover_pvs_deleted"], ["pvc-08519a57"])
        self.assertEqual(k.pvs, {})
        self.assertEqual(k.patches[0], "pvc-08519a57")
        self.assertLess([c[0] for c in k.calls].index("PATCH"), [c[0] for c in k.calls].index("POST"))

    def test_bound_leftover_pv_stops_before_restore(self):
        k = FakeKube(self.d)
        k.pvs["pvc-x"] = drill_pv("pvc-x", "Bound")
        with self.assertRaises(self.d.DrillError):
            self.d.run(k)
        self.assertNotIn("POST", [c[0] for c in k.calls])
        self.assertNotIn("PATCH", [c[0] for c in k.calls])

    def test_retain_pv_fails_fast(self):
        k = FakeKube(self.d, "patch-reverted")
        self.d.DEADLINE = 10 ** 6
        r = self.d.run(k)
        self.assertEqual(r["status"], "FAIL")
        self.assertIn("Released en Retain", r["cleanup_error"])
        self.assertEqual((k.pods, k.pvcs), ({}, {}))
        self.assertLess(r["total_seconds"], 60)

    def test_patch_denied_still_cleans(self):
        k = FakeKube(self.d, "patch-denied")
        r = self.d.run(k)
        self.assertEqual(r["status"], "FAIL")
        self.assertIn("403", r["cleanup_error"])
        self.assertEqual((k.pods, k.pvcs), ({}, {}))

    def test_pv_guard_mirror(self):
        old = drill_pv("p", "Released")
        ok = merge_patch(old, {"spec": {"persistentVolumeReclaimPolicy": "Delete"}})
        self.assertTrue(pv_guard_admits(old, ok))
        self.assertFalse(pv_guard_admits(old, merge_patch(old, {"spec": {"persistentVolumeReclaimPolicy": "Recycle"}})))
        self.assertFalse(pv_guard_admits(old, merge_patch(ok, {"spec": {"claimRef": {"namespace": "x"}}})))
        self.assertFalse(pv_guard_admits(old, merge_patch(ok, {"metadata": {"finalizers": None}})))
        self.assertFalse(pv_guard_admits(other_pv(), merge_patch(other_pv(), {"spec": {"persistentVolumeReclaimPolicy": "Delete"}})))

    def test_policies_and_bindings(self):
        adm = (DRILL_DIR / "admission.yaml").read_text()
        docs = [d for d in adm.split("\n---\n")]
        kinds = [(re.search(r"^kind: (\S+)", d, re.M).group(1), re.search(r"^  name: (\S+)", d, re.M).group(1))
                 for d in docs]
        policies = [n for kd, n in kinds if kd == "ValidatingAdmissionPolicy"]
        bindings = [n for kd, n in kinds if kd == "ValidatingAdmissionPolicyBinding"]
        self.assertEqual(sorted(policies), sorted(self.d.GUARDS))
        self.assertEqual(sorted(bindings), sorted(policies))
        for n in policies:  # the policy is declared before its binding
            self.assertLess(kinds.index(("ValidatingAdmissionPolicy", n)),
                            kinds.index(("ValidatingAdmissionPolicyBinding", n)))
        self.assertNotIn("ha-restore-test-guard\n", adm)
        pv = docs[kinds.index(("ValidatingAdmissionPolicy", "ha-restore-drill-pv-guard"))]
        for frag in ("system:serviceaccount:velero:ha-restore-drill", "oldObject.spec.storageClassName == 'longhorn-drill'",
                     "oldObject.spec.claimRef.namespace == 'home-assistant-restore-test'",
                     "object.spec.persistentVolumeReclaimPolicy == 'Delete'", "persistentvolumes/status"):
            self.assertIn(frag, pv)

    def test_hostnetwork_pod_stops_and_cleans(self):
        k = FakeKube(self.d, "hostnetwork")
        r = self.d.run(k)
        self.assertEqual(r["status"], "FAIL")
        self.assertIn("ARRET", r["error"])
        self.assertEqual((k.pods, k.pvcs), ({}, {}))

    def test_production_drift_fails(self):
        r = self.d.run(FakeKube(self.d, "prod-restart"))
        self.assertEqual(r["status"], "FAIL")
        self.assertFalse(r["prod_unchanged"])

    def test_preflight_refuses_leftovers(self):
        k = FakeKube(self.d)
        k.pods["left"] = {"metadata": {"name": "left"}, "spec": {}}
        with self.assertRaises(self.d.DrillError):
            self.d.run(k)
        self.assertNotIn("POST", [c[0] for c in k.calls])


if __name__ == "__main__":
    unittest.main(verbosity=1)
