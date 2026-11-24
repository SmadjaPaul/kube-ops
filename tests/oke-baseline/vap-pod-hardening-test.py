#!/usr/bin/env python3
"""Test statique de la VAP baseline-pod-hardening d'oracle-a1 (PLT-405).

Le refus reel d'un pod privilegie ne se prouve pas avec l'identite lecture seule d'OKE (aucun create,
kubectl-ro refuse tout dry-run). On evalue donc les expressions CEL de la VAP, telles que committees, avec
cel-python sur des objets pod / Deployment / ephemeralcontainers : les cas interdits doivent etre refuses,
les cas sains acceptes. On verifie aussi le binding (Deny, exemptions exactes). Ce n'est pas l'admission
reelle (apiserver) : le dry-run serveur reste a faire avec une identite d'ecriture (voir README du cluster).

Usage : python3 tests/oke-baseline/vap-pod-hardening-test.py   (pip install cel-python==0.5.0 pyyaml)
"""
import copy
import pathlib
import sys

import celpy
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOCS = list(yaml.safe_load_all((ROOT / "k8s/clusters/oracle-a1/guardrails/pod-hardening.yaml").read_text()))
POLICY = next(d for d in DOCS if d["kind"] == "ValidatingAdmissionPolicy")
BINDING = next(d for d in DOCS if d["kind"] == "ValidatingAdmissionPolicyBinding")
ENV = celpy.Environment()


def evaluate(expr, activation):
    return ENV.program(ENV.compile(expr)).evaluate(
        {k: celpy.json_to_cel(v) for k, v in activation.items()}
    )


def admitted(obj):
    """True si toutes les validations de la VAP passent pour `obj` (variables evaluees dans l'ordre)."""
    act = {"object": obj, "variables": {}}
    for var in POLICY["spec"]["variables"]:
        act["variables"][var["name"]] = json_py(evaluate(var["expression"], act))
    return [v["message"] for v in POLICY["spec"]["validations"] if not bool(evaluate(v["expression"], act))]


def json_py(v):
    if isinstance(v, (celpy.celtypes.MapType, dict)):
        return {str(k): json_py(x) for k, x in v.items()}
    if isinstance(v, (celpy.celtypes.ListType, list)):
        return [json_py(x) for x in v]
    if isinstance(v, celpy.celtypes.BoolType):
        return bool(v)
    if isinstance(v, (celpy.celtypes.IntType, celpy.celtypes.UintType)):
        return int(v)
    return str(v) if isinstance(v, celpy.celtypes.StringType) else v


def pod(**spec):
    s = {"containers": [{"name": "c", "image": "x"}]}
    s.update(spec)
    return {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "p"}, "spec": s}


def deployment(**spec):
    return {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "d"},
            "spec": {"template": {"spec": pod(**spec)["spec"]}}}


failures = []


def check(name, obj, should_deny, word=None):
    msgs = admitted(obj)
    ok = bool(msgs) == should_deny and (word is None or any(word in m for m in msgs))
    print(("ok   " if ok else "FAIL ") + name + (f" -> {msgs}" if msgs else ""))
    if not ok:
        failures.append(name)


priv = {"name": "c", "image": "x", "securityContext": {"privileged": True}}
check("positif : pod non privilegie accepte", pod(), False)
check("positif : pod securityContext durci accepte",
      pod(containers=[{"name": "c", "image": "x", "securityContext": {"privileged": False, "runAsNonRoot": True}}]), False)
check("positif : volume emptyDir accepte", pod(volumes=[{"name": "v", "emptyDir": {}}]), False)
check("positif : Deployment sain accepte", deployment(), False)
check("negatif : pod privilegie refuse", pod(containers=[priv]), True, "privileged")
check("negatif : initContainer privilegie refuse", pod(initContainers=[priv]), True, "privileged")
check("negatif : ephemeralContainer privilegie refuse (kubectl debug)",
      {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "p"}, "spec": {"ephemeralContainers": [priv]}}, True, "privileged")
check("negatif : Deployment avec conteneur privilegie refuse", deployment(containers=[priv]), True, "privileged")
check("negatif : hostNetwork refuse", pod(hostNetwork=True), True, "hostNetwork")
check("negatif : hostPID refuse", pod(hostPID=True), True, "hostPID")
check("negatif : hostIPC refuse", pod(hostIPC=True), True, "hostIPC")
check("negatif : hostPath refuse", pod(volumes=[{"name": "v", "hostPath": {"path": "/"}}]), True, "hostPath")
check("negatif : Deployment hostPath refuse", deployment(volumes=[{"name": "v", "hostPath": {"path": "/var"}}]), True, "hostPath")

spec = POLICY["spec"]
exempt = BINDING["spec"]["matchResources"]["namespaceSelector"]["matchExpressions"][0]
for name, cond in {
    "policy failurePolicy Fail (fail-closed)": spec["failurePolicy"] == "Fail",
    "binding validationActions == [Deny]": BINDING["spec"]["validationActions"] == ["Deny"],
    "binding lie a la policy": BINDING["spec"]["policyName"] == POLICY["metadata"]["name"],
    "exemptions exactes kube-system + netbird": exempt["operator"] == "NotIn" and sorted(exempt["values"]) == ["kube-system", "netbird"],
    "ressources couvertes : pods/ephemeralcontainers, deployments, jobs": all(
        r in sum([rr["resources"] for rr in spec["matchConstraints"]["resourceRules"]], [])
        for r in ("pods", "pods/ephemeralcontainers", "deployments", "daemonsets", "statefulsets", "jobs")),
}.items():
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)

if failures:
    print(f"VAP_POD_HARDENING_STATIC=FAIL ({len(failures)}): {failures}")
    sys.exit(1)
print("VAP_POD_HARDENING_STATIC=PASS")
