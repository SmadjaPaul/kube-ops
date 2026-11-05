#!/usr/bin/env python3
"""Read-only SparkyFitness admission report. No Secret, credential, or user-data GET.

Static source checks are deliberately conservative: they do not prove runtime
readiness. --runtime uses only scoped resource metadata/status, not Secret
objects and never executes kubectl apply, patch, exec, create or delete.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / "k8s/optional/sparkyfitness"
CHECKS = {
    "helm": ("argo-application.yaml", ["targetRevision: v1.11.0", "disableSignup: true",
                                     "autoRegister: false", "name: internal",
                                     "existingSecret: sparkyfitness-runtime"]),
    "database": ("database.yaml", ["name: sparkyfitness-db", "name: sparky_admin",
                                   "createrole: true", "storageClass: longhorn-bulk"]),
    "eso": ("external-secret.yaml", ["APP_SPARKYFITNESS_API_ENCRYPTION_KEY",
                                    "APP_SPARKYFITNESS_BETTER_AUTH_SECRET",
                                    "APP_SPARKYFITNESS_OIDC_CLIENT_ID",
                                    "APP_SPARKYFITNESS_OIDC_CLIENT_SECRET",
                                    "APP_SPARKYFITNESS_DB_APP_USERNAME",
                                    "APP_SPARKYFITNESS_DB_APP_PASSWORD"]),
    "backup": ("backup.yaml", ["APP_SPARKYFITNESS_CNPG_S3_ACCESS_KEY_ID",
                               "APP_SPARKYFITNESS_CNPG_S3_SECRET_ACCESS_KEY",
                               "sparkyfitness-postgresql-weekly"]),
    "policy": ("networkpolicy.yaml", ["sparkyfitness-server", "sparkyfitness-db-access"]),
}
BLOCKED_RUNTIME = [
    "OIDC_FAMILY_PASS", "RLS_ISOLATION_PASS",
    "CNPG_RESTORE_PASS", "UPLOAD_RESTORE_PASS",
    "WORKOUT_NUTRITION_PASS", "USER_READY",
]
ALLOWED = {
    "application": ("argocd", "personal-sparkyfitness"),
    "cluster": ("wellness", "sparkyfitness-db"),
    "externalsecret": ("wellness", ["sparkyfitness-runtime", "sparkyfitness-oidc",
                                   "sparkyfitness-appdb", "sparkyfitness-cnpg-hetzner-credentials"]),
    "objectstore": ("wellness", "sparkyfitness-hetzner-store"),
    "scheduledbackup": ("wellness", "sparkyfitness-postgresql-weekly"),
}

def static_checks(root=ROOT):
    package = root / "k8s/optional/sparkyfitness"
    gate = {}
    for name, (path, required) in CHECKS.items():
        target = package / path
        content = target.read_text() if target.is_file() else ""
        gate[name] = "PASS" if all(token in content for token in required) else "FAIL"
    for active in ("k8s/applications/platform/kustomization.yaml",
                   "k8s/applications/media/kustomization.yaml",
                   "k8s/applications/catalog/kustomization.yaml"):
        file = root / active
        if file.exists() and re.search(r"(?m)^\s*-\s+(?:\.\./)*sparkyfitness\s*$", file.read_text()):
            gate["dormant"] = "FAIL"
            break
    else:
        gate["dormant"] = "PASS"
    return gate

def kubectl_status(kind, namespace, name):
    # Args are strictly generated from constants, never shell input.
    cmd = ["kubectl", "-n", namespace, "get", kind, name, "-o", "json"]
    try:
        run = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=12)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return "BLOCKED"
    if run.returncode:
        return "BLOCKED"
    try:
        resource = json.loads(run.stdout)
    except json.JSONDecodeError:
        return "BLOCKED"
    status = resource.get("status", {})
    if not isinstance(status, dict):
        return "BLOCKED"
    if kind == "application":
        return "PASS" if status.get("sync", {}).get("status") == "Synced" and status.get("health", {}).get("status") == "Healthy" else "BLOCKED"
    if kind in ("externalsecret", "cluster", "objectstore"):
        conditions = status.get("conditions", [])
        return "PASS" if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions if isinstance(c, dict)) else "BLOCKED"
    # A ScheduledBackup existing is NOT a successful backup / restore.
    if kind == "scheduledbackup":
        return "PRESENT_NOT_PROVEN"
    return "BLOCKED"

def runtime_checks():
    result = {}
    for kind, (ns, names) in ALLOWED.items():
        if isinstance(names, str):
            names = [names]
        for name in names:
            result[f"{kind}/{ns}/{name}"] = kubectl_status(kind, ns, name)
    return result

def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", action="store_true", help="Read-only kubectl resource status; never Secret values")
    args = parser.parse_args(argv)
    source = static_checks()
    result = {
        "app": "SparkyFitness",
        "scope": "readonly",
        "source_contract": source,
        "runtime_resource_status": runtime_checks() if args.runtime else "NOT_EXECUTED",
        "gates": {gate: "NOT_EXECUTED" for gate in BLOCKED_RUNTIME},
        "deployed": "UNKNOWN" if args.runtime else "NOT_EXECUTED",
        "admission": "BLOCKED",
        "notes": [
            "Source contract is not proof of Doppler key presence or S3 least privilege",
            "Argo/ESO/CNPG Ready alone never proves signup, real-user isolation, or restore",
            "No application, account, secret, PVC or route is modified",
        ],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if all(value == "PASS" for value in source.values()) else 1

if __name__ == "__main__":
    sys.exit(main())
