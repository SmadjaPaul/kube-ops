#!/usr/bin/env python3
"""Negative tests: an application rendered through the golden path must not obtain
cluster-wide privileges. Two independent layers are evaluated per rendered object:

(a) AppProject apps-generated. A minimal re-implementation of Argo CD v3.5.1
    validateSyncPermissions (controller/sync.go, pkg/apis/application/v1alpha1/
    app_project_types.go): kind whitelist/blacklist (cluster kinds with name glob),
    namespace destinations with glob and `!` negation. The rules are read from the
    real manifest k8s/bootstrap/argocd-root/apps-generated-project.yaml, not copied.
    Limits: no RBAC of the controller, no impersonation, no sync hooks, no server
    side apply field ownership; only the destination/kind/name decision is modelled.

(b) Kyverno CLI on the ValidatingPolicy k8s/infrastructure/security/policies/
    apps-generated-boundary.yaml. Workloads are evaluated through the CLI's pod
    expansion (a Deployment's template is checked as a Pod).

A LEAK is an object admitted by BOTH layers while it is a fixture named evil-*.
A valid-* fixture must be admitted by BOTH layers. Output: JSON on stdout,
exit 1 on leak, on a valid fixture rejected, on a failed static check or on a
Kyverno error. Requires: python3 with PyYAML, kyverno CLI on PATH.
Also checks that the applications AppProject and the rendered applications roots
(kustomize --enable-helm, when kustomize is on PATH) carry no cluster RBAC.
"""
from __future__ import annotations

import fnmatch
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PROJECT = os.path.join(ROOT, "k8s/bootstrap/argocd-root/apps-generated-project.yaml")
APPS_PROJECT = os.path.join(ROOT, "k8s/bootstrap/argocd-root/applications-project.yaml")
POLICY = os.path.join(ROOT, "k8s/infrastructure/security/policies/apps-generated-boundary.yaml")
FIXTURES = os.path.join(ROOT, "tests/apps-generated/fixtures")
APPLICATIONS_ROOTS = [
    "media", "tools", "ai", "web", "automation", "games",
    "business/invoice-ninja", "catalog", "platform",
]
CLUSTER_RBAC = {("rbac.authorization.k8s.io", "ClusterRole"), ("rbac.authorization.k8s.io", "ClusterRoleBinding")}
CLUSTER_SERVER = "https://kubernetes.default.svc"


def load_yaml_docs(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


# ---------------------------------------------------------------- (a) Argo AppProject
def _glob(pattern: str, value: str) -> bool:
    if pattern.startswith("!"):
        return not fnmatch.fnmatchcase(value, pattern[1:])
    return fnmatch.fnmatchcase(value, pattern)


def _is_deny(pattern: str) -> bool:
    return pattern.startswith("!")


def destination_permitted(project: dict, server: str, namespace: str) -> bool:
    """Argo CD isDestinationMatched: any allow rule matches AND no deny rule rejects."""
    matched = False
    for item in project.get("spec", {}).get("destinations", []) or []:
        srv_ok = _glob(item.get("server", ""), server)
        ns_ok = _glob(item.get("namespace", ""), namespace)
        if srv_ok and ns_ok and not _is_deny(item.get("server", "")) and not _is_deny(item.get("namespace", "")):
            matched = True
        elif _is_deny(item.get("namespace", "")) and srv_ok and not ns_ok:
            return False
    return matched


def _gk_in(entries: list[dict], group: str, kind: str, name: str | None) -> bool:
    for e in entries or []:
        if fnmatch.fnmatchcase(group, e.get("group", "")) and fnmatch.fnmatchcase(kind, e.get("kind", "")):
            if name is None or fnmatch.fnmatchcase(name, e.get("name", "*") or "*"):
                return True
    return False


def resource_permitted(project: dict, obj: dict, namespaced: bool) -> tuple[bool, str]:
    spec = project.get("spec", {})
    api_version = obj.get("apiVersion", "")
    group = api_version.rsplit("/", 1)[0] if "/" in api_version else ""
    kind = obj.get("kind", "")
    name = obj.get("metadata", {}).get("name", "")
    if namespaced:
        wl = spec.get("namespaceResourceWhitelist")
        bl = spec.get("namespaceResourceBlacklist") or []
        if wl is not None and not _gk_in(wl, group, kind, None):
            return False, f"{group or 'core'}/{kind} not in namespaceResourceWhitelist"
        if _gk_in(bl, group, kind, None):
            return False, f"{group or 'core'}/{kind} in namespaceResourceBlacklist"
        return True, "kind allowed"
    wl = spec.get("clusterResourceWhitelist") or []
    bl = spec.get("clusterResourceBlacklist") or []
    if not _gk_in(wl, group, kind, name):
        return False, f"cluster-scoped {group or 'core'}/{kind} {name!r} not in clusterResourceWhitelist"
    if _gk_in(bl, group, kind, name):
        return False, f"cluster-scoped {group or 'core'}/{kind} {name!r} in clusterResourceBlacklist"
    return True, "cluster kind and name allowed"


def appproject_verdict(project: dict, obj: dict, namespaced: bool) -> tuple[bool, str]:
    ok, reason = resource_permitted(project, obj, namespaced)
    if not ok:
        return False, reason
    if namespaced:
        ns = obj.get("metadata", {}).get("namespace", "")
        if not destination_permitted(project, CLUSTER_SERVER, ns):
            return False, f"namespace {ns!r} not a permitted destination"
    return True, reason


# ---------------------------------------------------------------- (b) Kyverno CLI
SUMMARY = re.compile(r"pass: (\d+), fail: (\d+), warn: (\d+), error: (\d+), skip: (\d+)")


def kyverno_verdict(tmpdir: str, obj: dict, idx: int) -> tuple[bool | None, str]:
    path = os.path.join(tmpdir, f"obj-{idx}.yaml")
    with open(path, "w", encoding="utf-8") as fh:
        yaml.safe_dump(obj, fh)
    proc = subprocess.run(
        ["kyverno", "apply", POLICY, "--resource", path],
        capture_output=True, text=True, check=False,
    )
    out = proc.stdout + proc.stderr
    match = SUMMARY.search(out)
    if not match:
        return None, "kyverno produced no summary: " + out.strip()[-300:]
    _pass, fail, _warn, error, _skip = (int(x) for x in match.groups())
    if error:
        return None, f"kyverno error count {error}: " + out.strip()[-300:]
    failed = re.findall(r"policy (\S+) -> resource (\S+) failed", out)
    if fail:
        return False, "; ".join(sorted({p for p, _ in failed})) or "policy failed"
    return True, "no policy failed"


def kyverno_version() -> str:
    proc = subprocess.run(["kyverno", "version"], capture_output=True, text=True, check=False)
    return (proc.stdout.strip().splitlines() or ["unknown"])[0]


# ---------------------------------------------------------------- static checks
def static_checks() -> list[dict]:
    checks: list[dict] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    proj = load_yaml_docs(PROJECT)[0]
    spec = proj["spec"]
    cwl = spec.get("clusterResourceWhitelist") or []
    check("apps-generated: cluster whitelist is Namespace svc-* only",
          cwl == [{"group": "", "kind": "Namespace", "name": "svc-*"}], json.dumps(cwl))
    check("apps-generated: no ClusterRole/ClusterRoleBinding anywhere",
          not any((e.get("group"), e.get("kind")) in CLUSTER_RBAC for e in cwl + (spec.get("clusterResourceBlacklist") or [])))
    check("apps-generated: destinations all svc-* on in-cluster server",
          all(d.get("namespace", "").startswith("svc-") and d.get("server") == CLUSTER_SERVER for d in spec["destinations"]))
    check("apps-generated: no wildcard in namespaceResourceWhitelist",
          all("*" not in (e.get("kind", "") + e.get("group", "")) for e in spec["namespaceResourceWhitelist"]))
    bl = {(e.get("group"), e.get("kind")) for e in spec.get("namespaceResourceBlacklist", [])}
    check("apps-generated: blacklist names Role, RoleBinding, Secret",
          {("rbac.authorization.k8s.io", "Role"), ("rbac.authorization.k8s.io", "RoleBinding"), ("", "Secret")} <= bl)
    check("apps-generated: no roles (no non-admin sync or override)", "roles" not in spec)
    check("apps-generated: no syncWindows and no destinationServiceAccounts",
          "syncWindows" not in spec and "destinationServiceAccounts" not in spec)

    apps = load_yaml_docs(APPS_PROJECT)[0]
    acwl = apps["spec"].get("clusterResourceWhitelist") or []
    check("applications: cluster whitelist has no ClusterRole/ClusterRoleBinding",
          not any((e.get("group"), e.get("kind")) in CLUSTER_RBAC for e in acwl), json.dumps(acwl))
    check("applications: destination namespace miniflux allowed (PR 1593)",
          any(d.get("namespace") == "miniflux" for d in apps["spec"]["destinations"]))

    infra = load_yaml_docs(os.path.join(ROOT, "k8s/bootstrap/argocd-root/infrastructure-project.yaml"))[0]
    check("infrastructure: destination databases allowed (pg-shared-homelab)",
          any(d.get("namespace") == "databases" for d in infra["spec"]["destinations"]))

    pol = load_yaml_docs(POLICY)
    check("kyverno: every ValidatingPolicy denies (Deny), none is Audit-only",
          all(p.get("kind") == "ValidatingPolicy" and p["spec"]["validationActions"] == ["Deny"] for p in pol))
    return checks


def rendered_roots_check() -> list[dict]:
    """ClusterRole/ClusterRoleBinding must not be rendered by any applications root."""
    results: list[dict] = []
    if shutil.which("kustomize") is None:
        results.append({"check": "applications roots render", "ok": False,
                        "detail": "kustomize not on PATH: cannot prove the removal"})
        return results
    for root in APPLICATIONS_ROOTS:
        path = os.path.join(ROOT, "k8s/applications", root)
        proc = subprocess.run(["kustomize", "build", "--enable-helm", path],
                              capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            results.append({"check": f"render applications/{root}", "ok": False, "detail": proc.stderr[-300:]})
            continue
        docs = [d for d in yaml.safe_load_all(proc.stdout) if d]
        cluster_rbac = [f"{d['kind']}/{d['metadata']['name']}" for d in docs
                        if d.get("kind") in ("ClusterRole", "ClusterRoleBinding")]
        results.append({"check": f"applications/{root} has no cluster RBAC", "ok": not cluster_rbac,
                        "detail": ", ".join(cluster_rbac) or f"{len(docs)} objects"})
    return results


# ---------------------------------------------------------------- driver
def main() -> int:
    if shutil.which("kyverno") is None:
        print(json.dumps({"verdict": "FAIL", "error": "kyverno CLI not on PATH"}, indent=2))
        return 1

    report: dict = {"kyverno_cli": kyverno_version(), "argocd": "v3.5.1",
                    "static": static_checks() + rendered_roots_check(), "objects": [], "leaks": [],
                    "errors": []}
    project = load_yaml_docs(PROJECT)[0]

    fixtures = sorted(glob.glob(os.path.join(FIXTURES, "*.yaml")))
    if not fixtures:
        report["errors"].append("no fixtures")
    with tempfile.TemporaryDirectory() as tmp:
        idx = 0
        for fixture in fixtures:
            name = os.path.basename(fixture)
            expect_valid = name.startswith("valid-")
            for obj in load_yaml_docs(fixture):
                idx += 1
                kind = obj.get("kind", "")
                namespaced = kind not in ("Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition")
                ap_ok, ap_reason = appproject_verdict(project, obj, namespaced)
                ky_ok, ky_reason = kyverno_verdict(tmp, obj, idx)
                if ky_ok is None:
                    report["errors"].append(f"{name}:{kind}: {ky_reason}")
                admitted = bool(ap_ok) and ky_ok is True
                row = {
                    "fixture": name,
                    "object": f"{kind}/{obj.get('metadata', {}).get('name', '')}",
                    "namespace": obj.get("metadata", {}).get("namespace", ""),
                    "appproject": {"admitted": ap_ok, "reason": ap_reason},
                    "kyverno": {"admitted": ky_ok, "reason": ky_reason},
                    "admitted_by_both": admitted,
                }
                report["objects"].append(row)
                if not expect_valid and admitted:
                    report["leaks"].append(row)
                if expect_valid and not admitted:
                    report["errors"].append(f"valid object rejected: {row['fixture']} {row['object']}")

    failed_static = [c for c in report["static"] if not c["ok"]]
    ok = not report["leaks"] and not report["errors"] and not failed_static
    report["verdict"] = "PASS" if ok else "FAIL"
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
