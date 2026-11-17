"""Offline tests for scripts/mission/resume.py.

Run: python3 -m unittest discover -s scripts/mission/tests
Pure evaluation tests use fixtures in memory; git tests use a throwaway repository in a temp dir.
No network: gh is never called (prs=None means NOT_TESTED).
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import resume as r  # noqa: E402

KEY = "demo-mission"
MISSION = {
    "mission_key": KEY,
    "title": "demo",
    "attempt": 0,
    "steps": [
        {"id": "s1", "title": "premiere", "required": "STATIC", "branch": "claude/s1", "claimed": "pending"},
        {"id": "s2", "title": "deuxieme", "required": "STATIC", "branch": "claude/s2", "claimed": "pending"},
        {"id": "s3", "title": "troisieme", "required": "RUNTIME", "claimed": "pending"},
    ],
}


def ev(mission=MISSION, commits=(), branches=(), prs=None, attempt_file=None):
    m = json.loads(json.dumps(mission))
    if attempt_file is not None:
        m["attempt"] = attempt_file
    proofs, traces, max_attempt = r.mission_evidence(list(commits), KEY)
    return r.evaluate(m, proofs, traces, max_attempt, set(branches), prs), m


def commit(sha, step=None, attempt=None, key=KEY):
    t = {"Mission-Key": [key]}
    if step:
        t["Mission-Step"] = [step]
    if attempt is not None:
        t["Mission-Attempt"] = [str(attempt)]
    return {"sha": sha, "trailers": t}


class EvaluateTests(unittest.TestCase):
    def test_empty_state_starts_at_first_step_attempt_one(self):
        report, _ = ev()
        self.assertEqual(report["next"]["id"], "s1")
        self.assertEqual(report["next_attempt"], 1)
        self.assertEqual(report["done"], [])
        self.assertEqual(report["steps"][0]["reason"], "branche claude/s1 absente")
        self.assertEqual(report["steps"][2]["reason"], "aucune preuve Git")

    def test_branch_without_trailer_is_not_proof(self):
        report, _ = ev(branches=["claude/s1"])
        self.assertEqual(report["steps"][0]["status"], "A_FAIRE")
        self.assertIn("branche claude/s1 présente", report["steps"][0]["reason"])

    def test_proven_step_is_never_replayed(self):
        report, _ = ev(commits=[commit("aaaa1111", "s1", 1)])
        self.assertEqual(report["done"], ["s1"])
        self.assertEqual(report["steps"][0]["status"], "PROUVE")
        self.assertEqual(report["next"]["id"], "s2")

    def test_git_overrides_file_claim_in_both_directions(self):
        mission = json.loads(json.dumps(MISSION))
        mission["steps"][0]["claimed"] = "pending"   # fichier : pas fait
        mission["steps"][1]["claimed"] = "done"      # fichier : fait
        report, _ = ev(mission, commits=[commit("aaaa1111", "s1", 1)])
        self.assertEqual(report["steps"][0]["status"], "PROUVE")  # Git prouve s1 malgré le fichier
        self.assertEqual(report["steps"][1]["status"], "A_FAIRE")  # fichier dit done, Git non
        self.assertTrue(report["steps"][1]["contradicted"])
        self.assertEqual(report["next"]["id"], "s2")

    def test_new_attempt_replays_only_unproven_step(self):
        commits = [
            commit("aaaa1111", "s1", 1),
            commit("bbbb2222", None, 1),  # tentative 1 : travail sans preuve pour s2
        ]
        report, _ = ev(commits=commits)
        self.assertEqual(report["next"]["id"], "s2")
        self.assertEqual(report["next_attempt"], 2)
        self.assertEqual(report["traces"], [("bbbb2222", 1)])
        self.assertEqual(report["done"], ["s1"])

    def test_attempt_recorded_in_file_is_respected(self):
        report, _ = ev(attempt_file=3)
        self.assertEqual(report["observed_attempt"], 3)
        self.assertEqual(report["next_attempt"], 4)

    def test_ci_success_on_branch_raises_level_to_ci(self):
        prs = {"claude/s1": {"pr": "#10 OPEN", "ci": "SUCCESS"}, "claude/s2": {"pr": None, "ci": "AUCUN"}}
        mission = json.loads(json.dumps(MISSION))
        mission["steps"][0]["required"] = "CI"
        report, _ = ev(mission, commits=[commit("aaaa1111", "s1", 1)], prs=prs)
        self.assertEqual(report["steps"][0]["status"], "PROUVE")
        self.assertIn("CI", report["steps"][0]["reason"])

    def test_failing_ci_does_not_prove_a_ci_step(self):
        prs = {"claude/s1": {"pr": "#10 OPEN", "ci": "FAILURE"}, "claude/s2": {"pr": None, "ci": "AUCUN"}}
        mission = json.loads(json.dumps(MISSION))
        mission["steps"][0]["required"] = "CI"
        report, _ = ev(mission, commits=[commit("aaaa1111", "s1", 1)], prs=prs)
        self.assertEqual(report["steps"][0]["status"], "NON_PROUVE")
        self.assertIn("CI FAILURE", report["steps"][0]["reason"])

    def test_runtime_step_is_never_proven_by_git(self):
        commits = [commit("aaaa1111", "s1", 1), commit("bbbb2222", "s2", 1), commit("cccc3333", "s3", 1)]
        report, _ = ev(commits=commits)
        self.assertEqual(report["steps"][2]["status"], "NON_PROUVE")
        self.assertIn("hors Git", report["steps"][2]["reason"])
        self.assertEqual(report["next"]["id"], "s3")

    def test_incoherence_warning_when_later_step_proven_first(self):
        report, _ = ev(commits=[commit("bbbb2222", "s2", 1)])
        self.assertTrue(any("s2 prouvé" in w for w in report["warnings"]))

    def test_other_mission_commits_are_ignored(self):
        report, _ = ev(commits=[commit("aaaa1111", "s1", 1, key="autre-mission")])
        self.assertEqual(report["done"], [])
        self.assertEqual(report["next_attempt"], 1)

    def test_render_states_next_step_and_do_not_replay(self):
        report, m = ev(commits=[commit("aaaa1111", "s1", 1)])
        text = r.render(m, report, "hors ligne", "hors ligne")
        self.assertIn("NE PAS REJOUER (prouvées) : s1", text)
        self.assertIn("PROCHAINE ÉTAPE : s2", text)


class ValidationTests(unittest.TestCase):
    def test_duplicate_step_ids_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "missions").mkdir()
            bad = json.loads(json.dumps(MISSION))
            bad["steps"][1]["id"] = "s1"
            (Path(d) / "missions" / f"{KEY}.state.json").write_text(json.dumps(bad))
            with self.assertRaises(ValueError):
                r.load_mission(Path(d), KEY)

    def test_missing_file_is_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                r.load_mission(Path(d), KEY)


class GitIntegrationTests(unittest.TestCase):
    """Real git repository in a temp dir: trailers are read from commits on any ref."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="mission-resume-test-"))
        self.git("init", "-q", "-b", "main")
        (self.dir / "missions").mkdir()
        (self.dir / "missions" / f"{KEY}.state.json").write_text(json.dumps(MISSION))
        self.git("add", ".")
        self.commit("chore: init")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.dir), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            check=True, capture_output=True, text=True,
        ).stdout

    def commit(self, subject, trailers=()):
        msg = subject + "\n\n" + "\n".join(trailers) + ("\n" if trailers else "")
        self.git("commit", "-q", "--allow-empty", "-m", msg)

    def run_resume(self):
        return subprocess.run(
            [sys.executable, str(HERE.parent / "resume.py"), KEY, "--repo", str(self.dir), "--offline"],
            capture_output=True, text=True,
        )

    def test_empty_repository_with_state_file(self):
        out = self.run_resume()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("PROCHAINE ÉTAPE : s1", out.stdout)
        self.assertIn("Tentative suivante : 1", out.stdout)

    def test_proof_on_other_branch_is_seen_and_not_replayed(self):
        self.git("checkout", "-q", "-b", "claude/s1")
        self.commit("feat(s1): fait", ["Mission-Key: demo-mission", "Mission-Step: s1", "Mission-Attempt: 1"])
        self.git("checkout", "-q", "main")
        out = self.run_resume()
        self.assertIn("NE PAS REJOUER (prouvées) : s1", out.stdout)
        self.assertIn("PROCHAINE ÉTAPE : s2", out.stdout)

    def test_new_attempt_flag_writes_file(self):
        out = subprocess.run(
            [sys.executable, str(HERE.parent / "resume.py"), KEY, "--repo", str(self.dir), "--offline", "--new-attempt"],
            capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        written = json.loads((self.dir / "missions" / f"{KEY}.state.json").read_text())
        self.assertEqual(written["attempt"], 1)

    def test_missing_state_file_exits_2(self):
        (self.dir / "missions" / f"{KEY}.state.json").unlink()
        out = self.run_resume()
        self.assertEqual(out.returncode, 2)
        self.assertIn("fichier d'état absent", out.stderr)

    def test_invalid_key_rejected(self):
        out = subprocess.run(
            [sys.executable, str(HERE.parent / "resume.py"), "../etc", "--repo", str(self.dir), "--offline"],
            capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 2)


if __name__ == "__main__":
    unittest.main()
