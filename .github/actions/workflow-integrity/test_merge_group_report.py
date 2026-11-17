"""merge_group report: simulated merge_group event payload, real throwaway git repository."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "merge_group_report.py"


def run(cwd, *args):
    return subprocess.run(["python3", str(SCRIPT), *args], cwd=cwd, capture_output=True, text=True)


class MergeGroupReport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.addCleanup(self.tmp.cleanup)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.g = lambda *a: subprocess.check_output(["git", *a], cwd=self.dir, env=env).decode().strip()
        self.g("init", "-q")
        Path(self.dir, "a.txt").write_text("a")
        self.g("add", ".")
        self.g("commit", "-q", "-m", "base")
        self.base = self.g("rev-parse", "HEAD")

    def commit(self, path):
        p = Path(self.dir, path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")
        self.g("add", ".")
        self.g("commit", "-q", "-m", "c")
        return self.g("rev-parse", "HEAD")

    def test_reports_protected_paths_and_succeeds(self):
        head = self.commit(".github/workflows/x.yaml")
        r = run(self.dir, "--base-sha", self.base, "--head-sha", head)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("MERGE_GROUP_PROTECTED_PATHS=.github/workflows/x.yaml", r.stdout)

    def test_no_protected_paths(self):
        head = self.commit("docs/a.md")
        r = run(self.dir, "--base-sha", self.base, "--head-sha", head)
        self.assertEqual(r.returncode, 0)
        self.assertIn("MERGE_GROUP_PROTECTED_PATHS=-", r.stdout)

    def test_unreadable_diff_fails_closed(self):
        r = run(self.dir, "--base-sha", self.base, "--head-sha", "f" * 40)
        self.assertEqual(r.returncode, 1)
        self.assertIn("MERGE_GROUP_DIFF_UNREADABLE", r.stderr)

    def test_rejects_non_sha_arguments(self):
        r = run(self.dir, "--base-sha", "--output=x", "--head-sha", "main")
        self.assertNotEqual(r.returncode, 0)
        r = run(self.dir, "--base-sha", "main", "--head-sha", self.base)
        self.assertEqual(r.returncode, 1)
        self.assertIn("MERGE_GROUP_BAD_BASE_SHA", r.stderr)


if __name__ == "__main__":
    unittest.main()
