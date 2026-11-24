#!/usr/bin/env python3
"""PRD-76: drill de restauration Velero de Home Assistant, sans toucher la production.

Restaure le dernier backup Completed de velero-daily-home-assistant (pod
home-assistant-0 + PVC) dans home-assistant-restore-test, lit la ligne JSON du
vérificateur (pod neutralisé par la règle pods de restore-pvc-isolation),
supprime le pod et le PVC restaurés, puis compare la production avant/après.
Sortie : une ligne JSON finale `"drill": "ha-restore-drill"`, code 0 si PASS.
Aucun Secret lu, aucune valeur de jeton affichée.
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

API = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
VELERO_NS = "velero"
SOURCE_NS = "home-assistant"
TEST_NS = "home-assistant-restore-test"
SCHEDULE = "velero-daily-home-assistant"
MODIFIER = "restore-pvc-isolation"
PROD_PVC = "home-assistant-home-assistant-0"
PROD_POD = "home-assistant-0"
GUARDS = ["ha-restore-test-guard", "ha-restore-drill-restore-guard"]
RESOURCES = ["pods", "persistentvolumeclaims", "persistentvolumes"]
DEADLINE = int(os.environ.get("DRILL_DEADLINE_SECONDS", "1200"))
POLL = float(os.environ.get("DRILL_POLL_SECONDS", "5"))


class DrillError(Exception):
    pass


class Kube:
    def __init__(self, api=API, sa_dir=SA_DIR):
        self.api = api
        with open(os.path.join(sa_dir, "token")) as f:
            self._token = f.read().strip()
        self._ctx = ssl.create_default_context(cafile=os.path.join(sa_dir, "ca.crt"))

    def call(self, method, path, body=None, raw=False):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.api + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self._token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=self._ctx, timeout=30) as r:
                payload = r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            detail = e.read().decode(errors="replace")[:400]
            raise DrillError(f"{method} {path}: HTTP {e.code} {detail}") from None
        return payload.decode() if raw else json.loads(payload)


def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}", flush=True)


def latest_completed(backups):
    done = [b for b in backups if b.get("status", {}).get("phase") == "Completed"
            and b["metadata"]["name"].startswith(SCHEDULE + "-")]
    if not done:
        raise DrillError("aucun backup Completed de " + SCHEDULE)
    return max(done, key=lambda b: b["status"].get("completionTimestamp", ""))["metadata"]["name"]


def restore_body(name, backup):
    # Forme exacte admise par la ValidatingAdmissionPolicy ha-restore-drill-restore-guard.
    return {
        "apiVersion": "velero.io/v1",
        "kind": "Restore",
        "metadata": {"name": name, "namespace": VELERO_NS},
        "spec": {
            "backupName": backup,
            "includedNamespaces": [SOURCE_NS],
            "includedResources": list(RESOURCES),
            "namespaceMapping": {SOURCE_NS: TEST_NS},
            "restorePVs": True,
            "resourceModifier": {"kind": "ConfigMap", "name": MODIFIER},
        },
    }


def last_json_line(text):
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def prod_snapshot(k):
    pvc = k.call("GET", f"/api/v1/namespaces/{SOURCE_NS}/persistentvolumeclaims/{PROD_PVC}")
    pod = k.call("GET", f"/api/v1/namespaces/{SOURCE_NS}/pods/{PROD_POD}")
    if pvc is None or pod is None:
        raise DrillError("production illisible (PVC ou pod home-assistant absent)")
    restarts = sum(c.get("restartCount", 0) for c in pod.get("status", {}).get("containerStatuses", []))
    return {"pvc_uid": pvc["metadata"]["uid"], "pvc_volume": pvc["spec"].get("volumeName"),
            "pod_uid": pod["metadata"]["uid"], "pod_phase": pod.get("status", {}).get("phase"),
            "pod_restarts": restarts}


def test_objects(k):
    pods = k.call("GET", f"/api/v1/namespaces/{TEST_NS}/pods")["items"]
    pvcs = k.call("GET", f"/api/v1/namespaces/{TEST_NS}/persistentvolumeclaims")["items"]
    return pods, pvcs


def assert_no_host_network(pods):
    bad = [p["metadata"]["name"] for p in pods if p["spec"].get("hostNetwork")]
    if bad:
        raise DrillError("ARRET : pod hostNetwork dans " + TEST_NS + " : " + ",".join(bad))


def preflight(k):
    ns = k.call("GET", f"/api/v1/namespaces/{TEST_NS}")
    if ns is None or ns.get("status", {}).get("phase") != "Active":
        raise DrillError(TEST_NS + " absent ou non Active (sync Argo de velero-ha-restore-drill ?)")
    if ns["metadata"].get("labels", {}).get("pod-security.kubernetes.io/enforce") != "baseline":
        raise DrillError(TEST_NS + " sans Pod Security enforce=baseline")
    for g in GUARDS:
        if k.call("GET", f"/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies/{g}") is None:
            raise DrillError("ValidatingAdmissionPolicy absente : " + g)
    cm = k.call("GET", f"/api/v1/namespaces/{VELERO_NS}/configmaps/{MODIFIER}")
    rules = (cm or {}).get("data", {}).get("resource-modifier.yaml", "")
    for needle in ("groupResource: pods", "longhorn-drill", '"/spec/hostNetwork"'):
        if needle not in rules:
            raise DrillError(MODIFIER + " sans la règle attendue : " + needle)
    pods, pvcs = test_objects(k)
    if pods or pvcs:
        raise DrillError(TEST_NS + " non vide (drill précédent non nettoyé)")


def wait_for(fn, what, deadline):
    while time.time() < deadline:
        res = fn()
        if res is not None:
            return res
        time.sleep(POLL)
    raise DrillError("délai dépassé : " + what)


def cleanup(k, deadline, result):
    pods, pvcs = test_objects(k)
    volumes = [p["spec"].get("volumeName") for p in pvcs if p["spec"].get("volumeName")]
    for p in pods:
        k.call("DELETE", f"/api/v1/namespaces/{TEST_NS}/pods/{p['metadata']['name']}")
    for p in pvcs:
        k.call("DELETE", f"/api/v1/namespaces/{TEST_NS}/persistentvolumeclaims/{p['metadata']['name']}")
    wait_for(lambda: True if test_objects(k) == ([], []) else None, "nettoyage de " + TEST_NS, deadline)
    wait_for(lambda: True if all(k.call("GET", f"/api/v1/persistentvolumes/{v}") is None for v in volumes) else None,
             "suppression des PV du drill", deadline)
    result["cleanup"] = {"pods": len(pods), "pvcs": len(pvcs), "pvs_deleted": volumes}


def run(k, now=time.time):
    t0 = now()
    deadline = t0 + DEADLINE
    result = {"drill": "ha-restore-drill", "status": "FAIL"}
    preflight(k)
    before = prod_snapshot(k)
    result["prod_before"] = before
    backups = k.call("GET", f"/apis/velero.io/v1/namespaces/{VELERO_NS}/backups"
                     f"?labelSelector=velero.io%2Fschedule-name%3D{SCHEDULE}")["items"]
    backup = latest_completed(backups)
    name = "ha-restore-drill-" + time.strftime("%Y%m%d%H%M%S", time.gmtime(t0))
    result.update(backup=backup, restore=name)
    try:
        log(f"Restore {name} depuis {backup}")
        k.call("POST", f"/apis/velero.io/v1/namespaces/{VELERO_NS}/restores", restore_body(name, backup))

        def restore_done():
            pods, _ = test_objects(k)
            assert_no_host_network(pods)
            r = k.call("GET", f"/apis/velero.io/v1/namespaces/{VELERO_NS}/restores/{name}") or {}
            phase = r.get("status", {}).get("phase")
            return r if phase in ("Completed", "PartiallyFailed", "Failed", "FailedValidation") else None

        r = wait_for(restore_done, "Restore terminé", deadline)
        st = r.get("status", {})
        result["restore_phase"] = st.get("phase")
        result["restore_warnings"], result["restore_errors"] = st.get("warnings", 0), st.get("errors", 0)
        result["restore_seconds"] = round(now() - t0, 1)
        if st.get("phase") != "Completed":
            raise DrillError("Restore " + str(st.get("phase")))
        pvrs = k.call("GET", f"/apis/velero.io/v1/namespaces/{VELERO_NS}/podvolumerestores"
                      f"?labelSelector=velero.io%2Frestore-name%3D{name}")["items"]
        result["pvr"] = [{"volume": p["spec"].get("volume"), "phase": p.get("status", {}).get("phase"),
                          "bytes": p.get("status", {}).get("progress", {}).get("bytesDone")} for p in pvrs]
        if not pvrs or any(p["phase"] != "Completed" for p in result["pvr"]):
            raise DrillError("PodVolumeRestore absent ou non Completed")

        def verifier_done():
            pod = k.call("GET", f"/api/v1/namespaces/{TEST_NS}/pods/{PROD_POD}")
            if pod is None:
                raise DrillError("pod vérificateur absent")
            assert_no_host_network([pod])
            return pod if pod.get("status", {}).get("phase") in ("Succeeded", "Failed") else None

        pod = wait_for(verifier_done, "fin du vérificateur", deadline)
        logs = k.call("GET", f"/api/v1/namespaces/{TEST_NS}/pods/{PROD_POD}/log?container=ha-restore-verify", raw=True)
        verdict = last_json_line(logs)
        result["verifier"] = verdict
        result["verifier_phase"] = pod["status"]["phase"]
        result["verify_seconds"] = round(now() - t0, 1)
        if not verdict or verdict.get("status") != "PASS" or pod["status"]["phase"] != "Succeeded":
            raise DrillError("vérificateur FAIL")
        result["status"] = "PASS"
    except DrillError as e:
        result["error"] = str(e)
    finally:
        try:
            cleanup(k, max(deadline, now() + 300), result)
        except DrillError as e:
            result["status"] = "FAIL"
            result["cleanup_error"] = str(e)
    after = prod_snapshot(k)
    result["prod_after"] = after
    same = all(after[f] == before[f] for f in ("pvc_uid", "pvc_volume", "pod_uid", "pod_restarts"))
    result["prod_unchanged"] = same and after["pod_phase"] == "Running"
    if not result["prod_unchanged"]:
        result["status"] = "FAIL"
    result["total_seconds"] = round(now() - t0, 1)
    return result


def main():
    try:
        result = run(Kube())
    except DrillError as e:
        result = {"drill": "ha-restore-drill", "status": "FAIL", "error": str(e)}
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
