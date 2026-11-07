#!/usr/bin/env python3
"""Fail closed when the protected main-branch contract drifts."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any


REQUIRED_CHECKS = {"v1-contract", "docs-required", "workflow-integrity"}


def validate(protection: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    status = protection.get("required_status_checks")
    if not isinstance(status, dict):
        return ["required_status_checks is missing"]

    if status.get("strict") is not True:
        errors.append("required_status_checks.strict must be true")

    contexts = set(status.get("contexts", []))
    missing = sorted(REQUIRED_CHECKS - contexts)
    if missing:
        errors.append("missing required checks: " + ", ".join(missing))

    if protection.get("enforce_admins", {}).get("enabled") is not True:
        errors.append("enforce_admins must be enabled")
    if protection.get("allow_force_pushes", {}).get("enabled") is not False:
        errors.append("force-pushes must be disabled")
    if protection.get("allow_deletions", {}).get("enabled") is not False:
        errors.append("branch deletion must be disabled")

    return errors


def read_protection(repo: str, branch: str) -> dict[str, Any]:
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/branches/{branch}/protection"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "SmadjaPaul/kube-ops"))
    parser.add_argument("--branch", default="main")
    args = parser.parse_args()

    try:
        errors = validate(read_protection(args.repo, args.branch))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"MAIN_PROTECTION=BLOCKED ({type(exc).__name__})", file=sys.stderr)
        return 2

    if errors:
        print("MAIN_PROTECTION=DRIFT")
        for error in errors:
            print(f"- {error}")
        return 1

    print("MAIN_PROTECTION=PASS")
    print("REQUIRED_CHECKS=" + ",".join(sorted(REQUIRED_CHECKS)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
