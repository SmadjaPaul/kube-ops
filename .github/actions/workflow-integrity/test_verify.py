"""Base-only admission gate unit tests; no GitHub API or cluster interaction."""
import datetime as dt
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import verify as gate


NOW = dt.datetime(2026, 11, 5, 13, 0, tzinfo=dt.timezone.utc)


def example(**changes):
    row = {
        "repository": gate.REPOSITORY,
        "pr": 949,
        "changeFingerprint": "f" * 64,
        "paths": ["tests/harness/backup-audit-contract-test.sh"],
        "reason": "PLT-56: validated contract additions",
        "approvedBy": gate.OWNER,
        "expiresAt": "2026-11-06T13:00:00Z",
    }
    row.update(changes)
    return {"schemaVersion": 1, "admissions": [row]}


class AdmissionContract(unittest.TestCase):
    def _args(self, **updates):
        args = {
            "repo": gate.REPOSITORY,
            "base_ref": "main",
            "base_sha": "b" * 40,
            "pr": 949,
            "sha": "a" * 40,
            "author": gate.OWNER,
            "head_repo": gate.REPOSITORY,
            "head_ref": "refs/remotes/origin/pr-949",
        }
        args.update(updates)
        return SimpleNamespace(**args)

    def test_valid_exact_scope(self):
        self.assertEqual(len(gate.validate_registry(json.dumps(example()), NOW, True)), 1)

    def test_unauthorized_gate_change(self):
        for path in (
            gate.SELF,
            gate.GATE_DIR + "verify.py",
            gate.GATE_DIR + "test_verify.py",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                gate.validate_registry(json.dumps(example(paths=[path])), NOW, True)

    def test_reject_admitted_self_modification(self):
        with patch.object(gate, "changed_paths", return_value=[gate.GATE_DIR + "verify.py"]):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_reject_wildcards(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(paths=["tests/harness/*"])), NOW, True)

    def test_expiry_fail_closed(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(expiresAt="2026-11-05T12:00:00Z")), NOW, True)

    def test_reject_wrong_owner(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(approvedBy="agent")), NOW, True)

    def test_reject_duplicate_fingerprint(self):
        data = example()
        data["admissions"].append(dict(data["admissions"][0]))
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(data), NOW, True)

    def test_protected_path_matching(self):
        self.assertTrue(gate.protected("tests/harness/backup-audit-contract-test.sh"))
        self.assertTrue(gate.protected(".github/workflows/workflow-integrity.yaml"))
        self.assertFalse(gate.protected("docs/operations/backup-audit.md"))
        self.assertFalse(gate.protected(gate.REGISTRY))

    def test_rename_cannot_hide_protected_source_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(root), *args], stderr=subprocess.DEVNULL
                )

            git("init", "-q")
            git("config", "user.email", "tests@example.invalid")
            git("config", "user.name", "CI Test")
            source = root / "tests" / "harness" / "protected.sh"
            source.parent.mkdir(parents=True)
            source.write_text("#!/bin/sh\ntrue\n")
            git("add", ".")
            git("commit", "-qm", "add protected test")
            base = git("rev-parse", "HEAD").decode().strip()
            (root / "docs").mkdir()
            git("mv", "tests/harness/protected.sh", "docs/moved-protected.sh")
            git("commit", "-qam", "rename protected test")
            head = git("rev-parse", "HEAD").decode().strip()
            with patch.object(gate, "git_bytes", side_effect=git):
                paths = gate.changed_paths(base, head)
            self.assertIn("tests/harness/protected.sh", paths)
            self.assertIn("docs/moved-protected.sh", paths)
            self.assertTrue(any(gate.protected(path) for path in paths))

    def test_registry_change_must_be_single_file(self):
        with patch.object(gate, "changed_paths", return_value=[gate.REGISTRY, "docs/other.md"]):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_registry_change_by_nonowner(self):
        with patch.object(gate, "changed_paths", return_value=[gate.REGISTRY]):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(author="attacker"), NOW)

    def test_registry_change_from_fork(self):
        with patch.object(gate, "changed_paths", return_value=[gate.REGISTRY]):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(head_repo="attacker/kube-ops"), NOW)

    def test_head_sha_is_not_the_admission_key(self):
        document = json.dumps(example())
        paths = ["tests/harness/backup-audit-contract-test.sh"]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            gate.verify(self._args(sha="0" * 40), NOW)

    def test_exact_authorization_and_expiration(self):
        document = json.dumps(example())
        paths = ["tests/harness/backup-audit-contract-test.sh"]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            gate.verify(self._args(), NOW)
            with self.assertRaises(SystemExit):
                gate.verify(self._args(pr=950), NOW)

    def test_reject_changed_content(self):
        document = json.dumps(example())
        paths = ["tests/harness/backup-audit-contract-test.sh"]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="e" * 64), \
             patch.object(Path, "read_text", return_value=document):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_reject_added_protected_file(self):
        document = json.dumps(example())
        paths = [
            "tests/harness/backup-audit-contract-test.sh",
            "tests/harness/new-protected-test.sh",
        ]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_reject_deleted_protected_file(self):
        document = json.dumps(example())
        paths = [
            "tests/harness/backup-audit-contract-test.sh",
            "tests/harness/removed-protected-test.sh",
        ]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_reject_wrong_repository(self):
        with patch.object(
            gate,
            "changed_paths",
            return_value=["tests/harness/backup-audit-contract-test.sh"],
        ):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(repo="attacker/kube-ops"), NOW)

    def test_reject_incomplete_admitted_path_set(self):
        document = json.dumps(example())
        paths = [
            "tests/harness/backup-audit-contract-test.sh",
            "tests/harness/atlantis-plan-only-test.sh",
        ]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_reject_expired_base_entry(self):
        document = json.dumps(example(expiresAt="2026-11-05T12:00:00Z"))
        paths = ["tests/harness/backup-audit-contract-test.sh"]
        with patch.object(gate, "changed_paths", return_value=paths), \
             patch.object(gate, "change_fingerprint", return_value="f" * 64), \
             patch.object(Path, "read_text", return_value=document):
            with self.assertRaises(SystemExit):
                gate.verify(self._args(), NOW)

    def test_fingerprint_survives_registry_merge_and_branch_sync(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(root), *args], stderr=subprocess.DEVNULL
                )

            def commit(message):
                git("add", ".")
                git("commit", "-qm", message)
                return git("rev-parse", "HEAD").decode().strip()

            git("init", "-q")
            git("config", "user.email", "tests@example.invalid")
            git("config", "user.name", "CI Test")
            protected = root / "tests" / "harness" / "approved.sh"
            protected.parent.mkdir(parents=True)
            protected.write_text("base\n")
            base = commit("base")
            git("branch", "main", base)
            protected.write_text("base\napproved\n")
            feature = commit("approved change")
            with patch.object(gate, "git_bytes", side_effect=git):
                old_fingerprint = gate.change_fingerprint(base, feature)

            git("checkout", "-q", "main")
            registry = root / ".github" / "workflow-integrity-admissions.json"
            registry.parent.mkdir(parents=True)
            registry.write_text("registry merge\n")
            new_base = commit("merge registry admission")

            git("checkout", "-q", "-b", "pr-sync", feature)
            git("merge", "--no-edit", "main")
            synced = git("rev-parse", "HEAD").decode().strip()
            with patch.object(gate, "git_bytes", side_effect=git):
                self.assertEqual(old_fingerprint, gate.change_fingerprint(new_base, synced))

            git("checkout", "-q", "-b", "pr-rebase", feature)
            git("rebase", "-q", "main")
            rebased = git("rev-parse", "HEAD").decode().strip()
            with patch.object(gate, "git_bytes", side_effect=git):
                self.assertEqual(old_fingerprint, gate.change_fingerprint(new_base, rebased))

    def test_fingerprint_changes_for_nonprotected_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(root), *args], stderr=subprocess.DEVNULL
                )

            git("init", "-q")
            git("config", "user.email", "tests@example.invalid")
            git("config", "user.name", "CI Test")
            (root / "tracked.txt").write_text("base\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD").decode().strip()
            (root / "tests").mkdir()
            (root / "tests" / "protected.sh").write_text("approved\n")
            git("add", ".")
            git("commit", "-qm", "protected change")
            protected_head = git("rev-parse", "HEAD").decode().strip()
            with patch.object(gate, "git_bytes", side_effect=git):
                first = gate.change_fingerprint(base, protected_head)
            (root / "tracked.txt").write_text("unapproved\n")
            git("add", ".")
            git("commit", "-qm", "unapproved unrelated change")
            changed_head = git("rev-parse", "HEAD").decode().strip()
            with patch.object(gate, "git_bytes", side_effect=git):
                second = gate.change_fingerprint(base, changed_head)
            self.assertNotEqual(first, second)

    def test_base_must_be_ancestor(self):
        with patch.object(
            gate,
            "git_bytes",
            side_effect=subprocess.CalledProcessError(1, ["git", "merge-base"]),
        ):
            with self.assertRaises(ValueError):
                gate.change_fingerprint("base", "head")


if __name__ == "__main__":
    unittest.main()
