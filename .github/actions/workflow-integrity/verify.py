#!/usr/bin/env python3
"""Fail-closed owner admission for protected GitHub automation changes.

Executed ONLY from the trusted pull_request_target base checkout. The PR head
is used as inert git diff / JSON input; it is never imported or executed.
"""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

OWNER = "SmadjaPaul"
REPOSITORY = "SmadjaPaul/kube-ops"
REGISTRY = ".github/workflow-integrity-admissions.json"
SELF = ".github/workflows/workflow-integrity.yaml"
CONTRACT = "docs/contracts/agent-test-result-v1.schema.json"
ALLOWED_FIELDS = {"repository", "pr", "headSha", "paths", "reason", "approvedBy", "expiresAt"}
UTC_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
COMMITLINT = re.compile(
    r'\s*"@commitlint/(?:cli|config-conventional)"\s*:\s*"\^?[0-9]+\.[0-9]+\.[0-9]+"\s*,?\s*'
)


def deny(reason):
    print(f"WORKFLOW_INTEGRITY=FAIL\nADMISSION_DENIED={reason}", file=sys.stderr)
    raise SystemExit(1)


def git_bytes(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def safe_path(path):
    if not isinstance(path, str) or not path or any(ord(ch) < 32 or ord(ch) > 126 for ch in path):
        return False
    if any(ch in path for ch in "*?[]{}\\") or path.startswith("/") or "//" in path:
        return False
    return all(part not in ("", ".", "..") for part in path.split("/"))


def protected(path):
    return (
        path.startswith((".github/workflows/", ".github/actions/", "tests/harness/", "scripts/check-"))
        or path in (".justfile", CONTRACT, "package.json")
    )


def changed_paths(base, head):
    data = git_bytes("diff", "--name-only", "-z", base, head)
    return [p.decode("utf-8") for p in data.split(b"\0") if p]


def package_change_is_exempt(base, head):
    diff = git_bytes("diff", "--unified=0", base, head, "--", "package.json").decode("utf-8")
    for line in diff.splitlines():
        if line.startswith(("+++", "---", "@@")) or not line.startswith(("+", "-")):
            continue
        if not COMMITLINT.fullmatch(line[1:]):
            return False
    return True


def blocked_paths(paths, base, head):
    return sorted(p for p in paths if protected(p) and (
        p != "package.json" or not package_change_is_exempt(base, head)
    ))


def parse_utc(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ValueError("expiresAt must use UTC YYYY-MM-DDTHH:MM:SSZ")
    return dt.datetime.strptime(value, UTC_FORMAT).replace(tzinfo=dt.timezone.utc)


def validate_registry(raw, now, require_fresh=False):
    document = json.loads(raw)
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "admissions"}:
        raise ValueError("invalid registry fields")
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
        raise ValueError("invalid schemaVersion")
    entries = document["admissions"]
    if not isinstance(entries, list) or len(entries) > 32:
        raise ValueError("invalid admission count")
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != ALLOWED_FIELDS:
            raise ValueError("invalid admission fields")
        repo, number, sha = entry["repository"], entry["pr"], entry["headSha"]
        paths = entry["paths"]
        if repo != REPOSITORY or type(number) is not int or number <= 0:
            raise ValueError("invalid repository or PR number")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("invalid exact SHA")
        if entry["approvedBy"] != OWNER or not isinstance(entry["reason"], str):
            raise ValueError("owner/reason missing")
        if not entry["reason"].strip() or len(entry["reason"]) > 400:
            raise ValueError("invalid reason")
        if not isinstance(paths, list) or not paths or len(paths) > 40:
            raise ValueError("invalid path list")
        if any(not safe_path(p) or not protected(p) or p in (SELF, REGISTRY) for p in paths):
            raise ValueError("paths must be exact protected paths, never the gate or registry")
        if len(paths) != len(set(paths)):
            raise ValueError("duplicate path")
        expiry = parse_utc(entry["expiresAt"])
        if require_fresh and not (now < expiry <= now + dt.timedelta(days=7)):
            raise ValueError("owner admission expiry must be in the next 7 days")
        key = (repo, number, sha)
        if key in seen:
            raise ValueError("duplicate PR/SHA admission")
        seen.add(key)
    return entries


def verify(args, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    actual_head = git_bytes("rev-parse", args.head_ref).decode().strip()
    if actual_head != args.sha:
        deny("PR_HEAD_SHA_MISMATCH")
    paths = changed_paths(args.base_sha, args.head_ref)
    if REGISTRY in paths:
        if paths != [REGISTRY] or args.repo != REPOSITORY or args.base_ref != "main":
            deny("REGISTRY_PR_MUST_CHANGE_ONLY_REGISTRY_ON_MAIN")
        if args.author != OWNER or args.head_repo != REPOSITORY:
            deny("REGISTRY_PR_REQUIRES_OWNER_AUTHOR_AND_SAME_REPO")
        try:
            raw = git_bytes("show", f"{args.head_ref}:{REGISTRY}").decode("utf-8")
            entries = validate_registry(raw, now, require_fresh=True)
        except (ValueError, UnicodeError, subprocess.CalledProcessError) as exc:
            deny(f"INVALID_OWNER_REGISTRY:{exc}")
        print(f"WORKFLOW_INTEGRITY=OWNER_REGISTRY_CHANGE\nVALID_ADMISSIONS={len(entries)}")
        return

    blocked = blocked_paths(paths, args.base_sha, args.head_ref)
    if not blocked:
        print("WORKFLOW_INTEGRITY=PASS")
        return

    print("UNQUALIFIED_AUTOMATION_CHANGES=" + ",".join(blocked))
    if SELF in blocked:
        deny("SELF_MODIFYING_GATE_REQUIRES_SEPARATE_OWNER_BOOTSTRAP")
    if args.repo != REPOSITORY or args.base_ref != "main" or args.head_repo != REPOSITORY:
        deny("PROTECTED_CHANGES_REQUIRE_SAME_REPO_AND_MAIN")
    try:
        entries = validate_registry(Path(REGISTRY).read_text(encoding="utf-8"), now)
    except (OSError, ValueError, UnicodeError) as exc:
        deny(f"BASE_REGISTRY_INVALID:{exc}")
    matches = [row for row in entries if row["repository"] == args.repo
               and row["pr"] == args.pr and row["headSha"] == args.sha]
    if len(matches) != 1:
        deny("NO_EXACT_BASE_ADMISSION")
    admission = matches[0]
    if set(admission["paths"]) != set(blocked):
        deny("PROTECTED_PATH_SET_MISMATCH")
    if parse_utc(admission["expiresAt"]) <= now:
        deny("ADMISSION_EXPIRED")
    print("WORKFLOW_INTEGRITY=ADMITTED")
    print(f"ADMISSION_PR={args.pr}")
    print(f"ADMISSION_SHA={args.sha}")
    print(f"ADMISSION_PATHS={','.join(blocked)}")
    print(f"ADMISSION_EXPIRES_AT={admission['expiresAt']}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--base-ref", required=True)
    p.add_argument("--base-sha", required=True)
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--sha", required=True)
    p.add_argument("--author", required=True)
    p.add_argument("--head-repo", required=True)
    p.add_argument("--head-ref", required=True)
    verify(p.parse_args())


if __name__ == "__main__":
    main()
