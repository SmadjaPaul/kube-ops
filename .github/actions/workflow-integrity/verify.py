#!/usr/bin/env python3
"""Fail-closed owner admission for protected GitHub automation changes.

Executed ONLY from the trusted pull_request_target base checkout. The PR head
is used as inert git diff / JSON input; it is never imported or executed.
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

OWNER = "SmadjaPaul"
REPOSITORY = "SmadjaPaul/kube-ops"
REGISTRY = ".github/workflow-integrity-admissions.json"
SELF = ".github/workflows/workflow-integrity.yaml"
GATE_DIR = ".github/actions/workflow-integrity/"
CONTRACT = "docs/contracts/agent-test-result-v1.schema.json"
ALLOWED_FIELDS = {"repository", "pr", "changeFingerprint", "paths", "reason", "approvedBy", "expiresAt"}
# A pre-cutover registry entry for PR #997 is still on main. Honor existing
# time-limited SHA admissions until expiry; new admissions use fingerprints.
LEGACY_FIELDS = (ALLOWED_FIELDS - {"changeFingerprint"}) | {"headSha"}
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


# PLT-210: files that define what trusted CI executes and which checks are
# required. Any change to them needs an exact owner admission.
REQUIRED_ENTRYPOINTS = (
    CONTRACT,
    "package.json",
    "scripts/check-v1-active-contract.sh",
    "scripts/select-v1-contract-roots.sh",
    "scripts/backup-static-contract.sh",
    "scripts/check-agent-harness-contract.sh",
    "scripts/check-documentation-integrity.mjs",
)
# Contract tests are ordinary code: adding or extending them is free. Deleting
# one, or reducing its assertion markers, needs an owner admission.
GUARDED_PREFIXES = ("tests/harness/", "scripts/check-")
ASSERTION_MARKER = re.compile(
    r"\b(?:assert\w*|fail\w*|die)\b|\bexit\s+[1-9]|\|\|\s*\{|\bexpect\(|"
    r"raise\s+SystemExit|process\.exit\(\s*[1-9]"
)
COMMENT_LINE = re.compile(r"\s*(?:#|//)")


def protected(path):
    return path.startswith((".github/workflows/", ".github/actions/")) or path in REQUIRED_ENTRYPOINTS


def guarded(path):
    return path.startswith(GUARDED_PREFIXES) and not protected(path)


def admissible(path):
    return protected(path) or guarded(path)


def assertion_markers(revision, path):
    """Count non-comment assertion markers; None when the file is absent."""
    try:
        data = git_bytes("show", f"{revision}:{path}")
    except subprocess.CalledProcessError:
        return None
    lines = data.decode("utf-8", "replace").splitlines()
    return sum(1 for line in lines if not COMMENT_LINE.match(line) and ASSERTION_MARKER.search(line))


def weakens(path, ancestor, head):
    before = assertion_markers(ancestor, path)
    if before is None:
        return False
    after = assertion_markers(head, path)
    return after is None or after < before


def merge_base(base, head):
    return git_bytes("merge-base", base, head).decode("utf-8").strip()


def changed_paths(base, head):
    # Compare the PR head with the common ancestor, not with the current base
    # tip. The base branch may have received a late owner admission after the
    # PR was opened; that base-only change must not become a PR change.
    ancestor = merge_base(base, head)
    data = git_bytes("diff", "--no-renames", "--no-ext-diff", "--no-textconv", "--name-only", "-z", ancestor, head)
    return [p.decode("utf-8") for p in data.split(b"\0") if p]


def _changed_records(base, head):
    """Return the complete raw Git change without lossy line normalization."""
    try:
        git_bytes("merge-base", "--is-ancestor", base, head)
    except subprocess.CalledProcessError as exc:
        raise ValueError("base revision is not an ancestor of PR head") from exc

    raw = git_bytes("diff", "--no-renames", "--raw", "--abbrev=40", "-z", base, head, "--")
    fields = [field for field in raw.split(b"\0") if field]
    if len(fields) % 2:
        raise ValueError("invalid git raw diff output")
    records = []
    for index in range(0, len(fields), 2):
        header = fields[index].decode("ascii").split()
        if len(header) != 5 or not header[0].startswith(":"):
            raise ValueError("invalid git raw diff record")
        path = fields[index + 1].decode("utf-8", "surrogateescape")
        records.append({
            "path": path,
            "status": header[4],
            "oldMode": header[0][1:],
            "newMode": header[1],
            "oldBlob": header[2],
            "newBlob": header[3],
        })
    return sorted(records, key=lambda record: (record["path"], record["status"]))


def change_fingerprint(base, head, paths=None):
    """Hash changed paths, statuses, modes/types and Git blobs.

    PLT-210: with ``paths`` (the blocked set), only those records are bound,
    so a rebase or a fix to an unprotected file keeps the admission valid while
    any change to an admitted file still invalidates it.
    """
    records = _changed_records(base, head)
    if paths is not None:
        wanted = set(paths)
        records = [record for record in records if record["path"] in wanted]
    canonical = json.dumps(
        records,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def package_change_is_exempt(base, head):
    diff = git_bytes("diff", "--no-renames", "--no-ext-diff", "--no-textconv", "--unified=0", base, head, "--", "package.json").decode("utf-8")
    for line in diff.splitlines():
        if line.startswith(("+++", "---", "@@")) or not line.startswith(("+", "-")):
            continue
        if not COMMITLINT.fullmatch(line[1:]):
            return False
    return True


def blocked_paths(paths, base, head):
    ancestor = merge_base(base, head)
    blocked = []
    for path in paths:
        if protected(path):
            if path != "package.json" or not package_change_is_exempt(base, head):
                blocked.append(path)
        elif guarded(path) and weakens(path, ancestor, head):
            blocked.append(path)
    return sorted(blocked)


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
        if not isinstance(entry, dict) or set(entry) not in (ALLOWED_FIELDS, LEGACY_FIELDS):
            raise ValueError("invalid admission fields")
        repo, number = entry["repository"], entry["pr"]
        legacy = set(entry) == LEGACY_FIELDS
        fingerprint = entry["headSha"] if legacy else entry["changeFingerprint"]
        paths = entry["paths"]
        if repo != REPOSITORY or type(number) is not int or number <= 0:
            raise ValueError("invalid repository or PR number")
        pattern = r"[0-9a-f]{40}" if legacy else r"[0-9a-f]{64}"
        if not isinstance(fingerprint, str) or not re.fullmatch(pattern, fingerprint):
            raise ValueError("invalid admission fingerprint or legacy SHA")
        if entry["approvedBy"] != OWNER or not isinstance(entry["reason"], str):
            raise ValueError("owner/reason missing")
        if not entry["reason"].strip() or len(entry["reason"]) > 400:
            raise ValueError("invalid reason")
        if not isinstance(paths, list) or not paths or len(paths) > 40:
            raise ValueError("invalid path list")
        if any(not safe_path(p) or not admissible(p) or p in (SELF, REGISTRY) or p.startswith(GATE_DIR) for p in paths):
            raise ValueError("paths must be exact protected paths, never the gate or registry")
        if len(paths) != len(set(paths)):
            raise ValueError("duplicate path")
        expiry = parse_utc(entry["expiresAt"])
        if require_fresh and not (now < expiry <= now + dt.timedelta(days=7)):
            raise ValueError("owner admission expiry must be in the next 7 days")
        key = (repo, number, fingerprint)
        if key in seen:
            raise ValueError("duplicate PR/fingerprint admission")
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
    if SELF in blocked or any(path.startswith(GATE_DIR) for path in blocked):
        deny("SELF_MODIFYING_GATE_REQUIRES_SEPARATE_OWNER_BOOTSTRAP")
    if args.repo != REPOSITORY or args.base_ref != "main" or args.head_repo != REPOSITORY:
        deny("PROTECTED_CHANGES_REQUIRE_SAME_REPO_AND_MAIN")
    try:
        entries = validate_registry(Path(REGISTRY).read_text(encoding="utf-8"), now)
    except (OSError, ValueError, UnicodeError) as exc:
        deny(f"BASE_REGISTRY_INVALID:{exc}")
    try:
        fingerprint = change_fingerprint(args.base_sha, args.head_ref, blocked)
    except ValueError as exc:
        deny(f"INVALID_PR_GRAPH:{exc}")
    matches = [row for row in entries if row["repository"] == args.repo
               and row["pr"] == args.pr
               and (row.get("changeFingerprint") == fingerprint
                    or row.get("headSha") == args.sha)]
    if len(matches) != 1:
        deny("NO_EXACT_BASE_ADMISSION")
    admission = matches[0]
    if set(admission["paths"]) != set(blocked):
        deny("PROTECTED_PATH_SET_MISMATCH")
    if parse_utc(admission["expiresAt"]) <= now:
        deny("ADMISSION_EXPIRED")
    print("WORKFLOW_INTEGRITY=ADMITTED")
    print(f"ADMISSION_PR={args.pr}")
    if "changeFingerprint" in admission:
        print(f"ADMISSION_FINGERPRINT={fingerprint}")
    else:
        print(f"ADMISSION_LEGACY_HEAD_SHA={admission['headSha']}")
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
