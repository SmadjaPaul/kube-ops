"""Offline tests for the dispatcher: selection, sort, locks, claude command, JSON parsing.

Run: python3 -m unittest discover -s scripts/dispatcher/tests
No network: the Linear client is never instantiated with a key.
"""

import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import dispatch  # noqa: E402
import selection as sel  # noqa: E402

FIX = HERE / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.queue = load("queue.json")["queue"]

    def test_order_follows_d10_then_priority_then_age(self):
        eligible, _ = sel.select(self.queue, "local")
        self.assertEqual(
            [i["identifier"] for i in eligible],
            ["PLT-5", "PLT-4", "PLT-8", "PLT-3", "PLT-2", "PLT-6", "PLT-1", "PLT-7"],
        )

    def test_rejections_and_reasons(self):
        _, rejected = sel.select(self.queue, "local")
        reasons = {i["identifier"]: r for i, r in rejected}
        self.assertEqual(reasons["PLT-20"], "label agent:codex")
        self.assertEqual(reasons["PLT-21"], "label Needs-operator")
        self.assertEqual(reasons["PLT-22"], "label Différé")
        self.assertEqual(reasons["PLT-23"], "pas exec:local")
        self.assertEqual(reasons["PLT-24"], "sans label agent:haiku|sonnet|opus")
        self.assertEqual(reasons["PLT-25"], "bloqué par PLT-93")
        self.assertEqual(reasons["PLT-26"], "statut Backlog")
        self.assertEqual(reasons["PLT-27"], "sans Agent-ready")
        self.assertTrue(reasons["PLT-28"].startswith("plusieurs labels agent:*"))
        self.assertEqual(reasons["PLT-29"], "déjà verrouillé")

    def test_finished_blockers_and_non_block_relations_do_not_block(self):
        plt8 = next(i for i in self.queue if i["identifier"] == "PLT-8")
        self.assertEqual(sel.open_blockers(plt8), [])

    def test_cloud_lane_only_takes_exec_cloud(self):
        eligible, _ = sel.select(self.queue, "cloud")
        self.assertEqual([i["identifier"] for i in eligible], ["PLT-23"])

    def test_unknown_lane_rejected(self):
        with self.assertRaises(ValueError):
            sel.select(self.queue, "codex")


class LockTests(unittest.TestCase):
    def test_three_hour_rule_uses_last_comment_then_updated_at(self):
        data = load("locks.json")
        now = sel.parse_ts(data["now"])
        active, expired = sel.classify_locks(data["locked"], now)
        self.assertEqual([i["identifier"] for i in active], ["PLT-40", "PLT-42"])
        self.assertEqual([i["identifier"] for i in expired], ["PLT-41", "PLT-43"])


class ClaudeCommandTests(unittest.TestCase):
    def test_command_bounds_come_from_model_table(self):
        queue = load("queue.json")["queue"]
        plt2 = next(i for i in queue if i["identifier"] == "PLT-2")  # agent:haiku
        with mock.patch.dict("os.environ", {"DISPATCH_PERMISSION_MODE": ""}):
            cmd = dispatch.claude_command(plt2, "local")
        self.assertEqual(cmd[:2], ["claude", "-p"])
        args = dict(zip(cmd[2:-1:2], cmd[3:-1:2]))
        self.assertEqual(args["--model"], "haiku")
        self.assertEqual(args["--effort"], "low")
        self.assertEqual(args["--max-turns"], "8")
        self.assertEqual(args["--output-format"], "json")
        self.assertIn("--max-budget-usd", args)
        self.assertIn("PLT-2", cmd[-1])
        self.assertLessEqual(len(cmd[-1].splitlines()), 8)

    def test_prompt_slices_large_tickets_instead_of_refusing(self):
        queue = load("queue.json")["queue"]
        prompt = dispatch.claude_command(queue[0], "local")[-1]
        self.assertIn("première tranche livrable", prompt)
        self.assertIn("ne refuse pas", prompt)
        self.assertIn("RUNTIME", prompt)
        self.assertIn("worktree neuf depuis origin/main", prompt)
        self.assertIn("aucun apply hors CI", prompt)

    def test_permission_mode_comes_from_environment(self):
        queue = load("queue.json")["queue"]
        with mock.patch.dict("os.environ", {"DISPATCH_PERMISSION_MODE": "bypassPermissions"}):
            cmd = dispatch.claude_command(queue[0], "local")
        self.assertEqual(cmd[cmd.index("--permission-mode") + 1], "bypassPermissions")

    def test_table_covers_the_three_models(self):
        self.assertEqual(
            {k: (v["effort"], v["max_turns"]) for k, v in sel.MODEL_TABLE.items()},
            {"agent:haiku": ("low", 8), "agent:sonnet": ("medium", 35), "agent:opus": ("high", 60)},
        )


class RunSummaryTests(unittest.TestCase):
    def test_success_json(self):
        out = json.dumps({"type": "result", "subtype": "success", "is_error": False, "num_turns": 7,
                          "result": "PR #1\nok", "total_cost_usd": 0.42,
                          "usage": {"input_tokens": 10, "output_tokens": 20,
                                    "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40}})
        run = dispatch.summarize_run(0, out, "")
        self.assertTrue(run["ok"])
        self.assertEqual((run["num_turns"], run["tokens_out"], run["cache_write"]), (7, 20, 40))
        issue = load("queue.json")["queue"][0]
        body = dispatch.checkpoint_body(issue, "local", run)
        self.assertIn("Tours : 7", body)
        self.assertIn("0.4200 USD", body)

    def test_max_turns_is_a_failure(self):
        out = json.dumps({"subtype": "error_max_turns", "is_error": False, "num_turns": 8, "usage": {}})
        run = dispatch.summarize_run(0, out, "")
        self.assertFalse(run["ok"])
        self.assertEqual(run["cause"], "error_max_turns")

    def test_crash_without_json(self):
        run = dispatch.summarize_run(1, "", "boom")
        self.assertFalse(run["ok"])
        self.assertNotIn("boom", run["cause"])
        self.assertIn("4 octets", run["cause"])

    def test_measure_line_full(self):
        out = json.dumps({"subtype": "success", "is_error": False, "num_turns": 7,
                          "result": "PR https://github.com/x/y/pull/1\nChecks: ok\n"
                                    "Etat: Done\nBlocage éventuel : aucun\nSuite: rien",
                          "total_cost_usd": 0.42, "subagents": [{"id": 1}, {"id": 2}],
                          "usage": {"input_tokens": 10, "output_tokens": 20,
                                    "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40}})
        run = dispatch.summarize_run(0, out, "")
        self.assertEqual(run["outcome"], "pr-valide")
        self.assertEqual(run["sub_agents"], 2)
        issue = load("queue.json")["queue"][0]
        body = dispatch.checkpoint_body(issue, "local", run)
        self.assertIn("- Issue : succès", body)  # existing lines unchanged
        self.assertIn("- Tours : 7", body)
        self.assertIn("0.4200 USD", body)
        self.assertIn("mesure: in=10 out=20 cache_read=30 cache_create=40 tours=7 "
                      "sous_agents=2 cout_usd=0.4200 issue=pr-valide", body.splitlines())

    def test_measure_line_unknowns_are_na(self):
        # No usage object, no cost, no sub-agent field: every unknown prints n/a, never 0.
        out = json.dumps({"subtype": "success", "is_error": False, "result": "PR #2"})
        run = dispatch.summarize_run(0, out, "")
        self.assertIsNone(run["tokens_in"])
        self.assertIn("mesure: in=n/a out=n/a cache_read=n/a cache_create=n/a tours=n/a "
                      "sous_agents=n/a cout_usd=n/a issue=pr-valide", dispatch.measure_line(run))

    def test_measure_line_crash_is_echec(self):
        run = dispatch.summarize_run(-1, "", "")
        line = dispatch.measure_line(run)
        self.assertTrue(line.endswith("issue=echec"))
        self.assertIn("in=n/a", line)

    def test_blocage_line_marks_blocage(self):
        out = json.dumps({"subtype": "success", "is_error": False,
                          "result": "PR none\nEtat: In Progress\nChecks: non lancés\n"
                                    "Blocage éventuel : Needs-operator, accès Doppler\nSuite: attente Paul",
                          "usage": {}})
        run = dispatch.summarize_run(0, out, "")
        self.assertTrue(run["ok"])
        self.assertEqual(run["outcome"], "blocage")
        self.assertTrue(dispatch.measure_line(run).endswith("issue=blocage"))

    def test_subagents_non_numeric_is_na(self):
        self.assertIsNone(dispatch.count_subagents({}))
        self.assertIsNone(dispatch.count_subagents({"subagents": True}))
        self.assertEqual(dispatch.count_subagents({"subagents": 3}), 3)

    def test_blocker_detection_ignores_empty_values(self):
        self.assertFalse(dispatch.has_blocker("Blocage éventuel : aucun"))
        self.assertFalse(dispatch.has_blocker("**Blocage éventuel** : -"))
        self.assertTrue(dispatch.has_blocker("**Blocage éventuel** : Doppler absent"))


class ProgressTests(unittest.TestCase):
    def test_fingerprint_ignores_dispatcher_comments(self):
        issue = {"attachments": {"nodes": [{"url": "https://github.com/o/r/pull/12"}, {"url": "https://x/doc"}]},
                 "comments": {"nodes": [
                     {"createdAt": "2026-11-12T01:00:00Z", "body": "PR #12 ouverte"},
                     {"createdAt": "2026-11-12T02:00:00Z", "body": "**Checkpoint dispatcher** (voie local)"},
                     {"createdAt": "2026-11-12T03:00:00Z", "body": "Relais de nuit : PLT-1 est sauté"}]}}
        self.assertEqual(dispatch.progress_fingerprint(issue),
                         "pr=1 liens=2 commentaires=1 dernier=2026-11-12T01:00:00Z")

    def test_fingerprint_of_empty_ticket(self):
        self.assertEqual(dispatch.progress_fingerprint({}), "pr=0 liens=0 commentaires=0 dernier=-")


class DryRunTests(unittest.TestCase):
    """End-to-end dry-run on a snapshot: no key, no network, no subprocess."""

    def _run(self, *argv):
        buf = io.StringIO()
        with mock.patch.dict("os.environ", {}, clear=True), \
                mock.patch.object(dispatch.subprocess, "run", side_effect=AssertionError("no exec")), \
                mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=AssertionError("no net")), \
                redirect_stdout(buf):
            code = dispatch.main(list(argv))
        return code, buf.getvalue()

    def test_dry_run_snapshot_picks_but_respects_active_lock(self):
        snap = str(FIX / "snapshot-2026-11-11.json")
        with mock.patch.object(sel, "utcnow", return_value=sel.parse_ts("2026-11-11T22:00:00Z")):
            code, out = self._run("--lane", "local", "--dry-run", "--snapshot", snap)
        self.assertEqual(code, 0)
        self.assertIn("choisi : PLT-198", out)
        self.assertIn("occupée par PLT-197", out)

    def test_dry_run_snapshot_after_expiry_would_lock(self):
        snap = str(FIX / "snapshot-2026-11-11.json")
        with mock.patch.object(sel, "utcnow", return_value=sel.parse_ts("2026-11-12T01:00:00Z")):
            code, out = self._run("--lane", "local", "--dry-run", "--snapshot", snap)
        self.assertEqual(code, 0)
        self.assertIn("verrou expiré", out)
        self.assertIn("poserait wip:claude-local", out)

    def test_resume_candidates_in_progress_without_lock(self):
        issues = load("resume.json")["in_progress"]
        self.assertEqual([i["identifier"] for i in sel.resume_candidates(issues, "local")], ["PLT-200"])
        self.assertEqual([i["identifier"] for i in sel.resume_candidates(issues, "cloud")], ["PLT-303"])

    def test_dry_run_lists_tickets_to_resume_before_empty_queue(self):
        snap = str(FIX / "resume.json")
        with mock.patch.object(sel, "utcnow", return_value=sel.parse_ts("2026-11-12T01:00:00Z")):
            code, out = self._run("--lane", "local", "--dry-run", "--snapshot", snap)
        self.assertEqual(code, 0)
        self.assertIn("à reprendre : PLT-200", out)
        self.assertNotIn("PLT-301", out)
        self.assertIn("file vide pour la voie local", out)

    def test_skip_list_is_never_chosen_and_progress_is_printed(self):
        snap = str(FIX / "snapshot-2026-11-11.json")
        with mock.patch.object(sel, "utcnow", return_value=sel.parse_ts("2026-11-12T01:00:00Z")):
            code, out = self._run("--lane", "local", "--dry-run", "--snapshot", snap)
            self.assertIn("choisi : PLT-198", out)
            self.assertRegex(out, r"progrès : PLT-198 pr=\d+ liens=\d+ commentaires=\d+ dernier=")
            code, out = self._run("--lane", "local", "--dry-run", "--snapshot", snap, "--skip", "PLT-198")
        self.assertEqual(code, 0)
        self.assertIn("écarté : PLT-198 (sauté cette nuit par le superviseur)", out)
        self.assertNotIn("choisi : PLT-198", out)

    def test_invalid_skip_identifier_is_rejected(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self._run("--lane", "local", "--dry-run", "--skip", "PLT-1;rm")

    def test_snapshot_requires_dry_run_and_missing_key_fails_cleanly(self):
        snap = str(FIX / "snapshot-2026-11-11.json")
        self.assertEqual(self._run("--lane", "local", "--snapshot", snap)[0], 2)
        self.assertEqual(self._run("--lane", "local", "--dry-run")[0], 2)


class FakeLinear:
    """In-memory stand-in for dispatch.Linear: records every mutation."""

    def __init__(self, queue, locked=(), fail=None, racer=None):
        self._queue, self._locked = queue, list(locked)
        self.fail, self.racer = fail or {}, racer
        self.labels = {}  # issue id -> set of label ids
        self.states, self.comments = {}, []

    def queue(self):
        return self._queue

    def locked(self, lane):
        found = [i for i in self._queue if "lock" in self.labels.get(i["id"], set())]
        if self.racer:
            found.append(self.racer)
        return list(self._locked) + found

    def label_id(self, name):
        return "lock"

    def state_id(self, name):
        return name

    def add_label(self, issue_id, label_id):
        self.labels.setdefault(issue_id, set()).add(label_id)

    def remove_label(self, issue_id, label_id):
        self.labels.setdefault(issue_id, set()).discard(label_id)

    def set_state(self, issue_id, state_id):
        if self.fail.get("set_state") == state_id:
            raise RuntimeError("set_state boom")
        self.states[issue_id] = state_id

    def comment(self, issue_id, body):
        self.comments.append((issue_id, body))

    def issue_detail(self, ident):
        return {"id": f"uuid-{ident}", "identifier": ident}


SUCCESS = json.dumps({"subtype": "success", "is_error": False, "num_turns": 3, "result": "ok",
                      "total_cost_usd": 0.1, "usage": {"input_tokens": 1, "output_tokens": 2}})


class RealRunTests(unittest.TestCase):
    """run() in real mode against FakeLinear; claude is a mocked subprocess."""

    def setUp(self):
        self.queue = load("queue.json")["queue"]
        self.top = "uuid-PLT-5"
        self.args = dispatch.argparse.Namespace(lane="local", dry_run=False, snapshot=None, skip=[], expect=None)

    def _run(self, fake, proc_stdout=SUCCESS, proc_rc=0, proc_stderr=""):
        proc = mock.Mock(returncode=proc_rc, stdout=proc_stdout, stderr=proc_stderr)
        with mock.patch.object(dispatch.subprocess, "run", return_value=proc) as sp, \
                mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=AssertionError("no net")), \
                redirect_stdout(io.StringIO()):
            code = dispatch.run(self.args, linear=fake)
        return code, sp

    def assertUnlocked(self, fake):
        self.assertNotIn("lock", fake.labels.get(self.top, set()))

    def test_success_comments_and_unlocks(self):
        fake = FakeLinear(self.queue)
        code, sp = self._run(fake)
        self.assertEqual(code, 0)
        self.assertEqual(fake.states[self.top], "In Progress")
        self.assertIn("Tours : 3", fake.comments[-1][1])
        self.assertUnlocked(fake)
        self.assertIn("--max-turns", sp.call_args[0][0])

    def test_set_state_failure_still_unlocks(self):
        fake = FakeLinear(self.queue, fail={"set_state": "In Progress"})
        with self.assertRaises(RuntimeError):
            self._run(fake)
        self.assertUnlocked(fake)

    def test_summarize_failure_still_unlocks_and_returns_to_todo(self):
        fake = FakeLinear(self.queue)
        with mock.patch.object(dispatch, "summarize_run", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self._run(fake)
        self.assertUnlocked(fake)
        self.assertEqual(fake.states[self.top], "Todo")

    def test_failed_run_returns_to_todo_without_raw_stderr(self):
        fake = FakeLinear(self.queue)
        code, _ = self._run(fake, proc_stdout="", proc_rc=1,
                            proc_stderr="token lin_api_SECRET at https://example.invalid/x")
        self.assertEqual(code, 1)
        self.assertEqual(fake.states[self.top], "Todo")
        body = fake.comments[-1][1]
        self.assertNotIn("SECRET", body)
        self.assertNotIn("https://", body)
        self.assertIn("octets", body)
        self.assertUnlocked(fake)

    def test_lost_race_releases_lock_and_does_not_run(self):
        racer = {"id": "uuid-PLT-99", "identifier": "PLT-99", "createdAt": "2026-11-01T00:00:00Z",
                 "updatedAt": "2026-11-01T00:00:00Z"}
        fake = FakeLinear(self.queue, racer=racer)
        # Our own lock is newer than the racer's.
        for issue in self.queue:
            issue["updatedAt"] = "2026-11-11T12:00:00Z"
        code, sp = self._run(fake)
        self.assertEqual(code, 0)
        sp.assert_not_called()
        self.assertNotIn(self.top, fake.states)
        self.assertUnlocked(fake)

    def test_expired_lock_is_removed_and_returned_to_todo(self):
        stale = load("locks.json")["locked"][3]  # PLT-43, updatedAt 08:00
        fake = FakeLinear([], locked=[stale])
        with mock.patch.object(sel, "utcnow", return_value=sel.parse_ts("2026-11-11T12:00:00Z")):
            self._run(fake)
        self.assertEqual(fake.states[stale["id"]], "Todo")
        self.assertTrue(any(i == stale["id"] and "remis en Todo" in b for i, b in fake.comments))

    def test_expect_mismatch_does_not_lock_or_run(self):
        self.args.expect = "PLT-4"  # PLT-5 sorts first
        fake = FakeLinear(self.queue)
        code, sp = self._run(fake)
        self.assertEqual(code, 3)
        sp.assert_not_called()
        self.assertEqual(fake.labels, {})

    def test_expect_match_and_skip_run_the_expected_ticket(self):
        self.args.expect, self.args.skip = "PLT-4", ["PLT-5"]
        fake = FakeLinear(self.queue)
        code, sp = self._run(fake)
        self.assertEqual(code, 0)
        self.assertIn("PLT-4", sp.call_args[0][0][-1])
        self.assertEqual(fake.states["uuid-PLT-4"], "In Progress")

    def test_usage_limit_prints_only_the_reset_fragment(self):
        fake = FakeLinear(self.queue)
        limit = json.dumps({"subtype": "success", "is_error": True, "result": "You've hit your limit · resets 3am"})
        buf = io.StringIO()
        proc = mock.Mock(returncode=1, stdout=limit, stderr="token lin_api_SECRET")
        with mock.patch.object(dispatch.subprocess, "run", return_value=proc), redirect_stdout(buf):
            code = dispatch.run(self.args, linear=fake)
        self.assertEqual(code, 1)
        self.assertIn("limite d'usage : usage limit, resets 3am", buf.getvalue())
        self.assertNotIn("SECRET", buf.getvalue())
        self.assertEqual(fake.states[self.top], "Todo")

    def test_plain_failure_prints_no_usage_limit(self):
        buf = io.StringIO()
        proc = mock.Mock(returncode=1, stdout="", stderr="boom")
        with mock.patch.object(dispatch.subprocess, "run", return_value=proc), redirect_stdout(buf):
            dispatch.run(self.args, linear=FakeLinear(self.queue))
        self.assertNotIn("limite d'usage", buf.getvalue())

    def test_comment_skip_posts_one_note(self):
        fake = FakeLinear(self.queue)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(dispatch.comment_skip("PLT-172", "2 échecs consécutifs", linear=fake), 0)
        self.assertEqual(len(fake.comments), 1)
        self.assertEqual(fake.comments[0][0], "uuid-PLT-172")
        self.assertTrue(fake.comments[0][1].startswith("Relais de nuit : PLT-172 est sauté"))

    def test_sigterm_becomes_system_exit_so_the_ticket_is_handed_back(self):
        fake = FakeLinear(self.queue)
        with mock.patch.object(dispatch, "summarize_run", side_effect=lambda *a: dispatch._sigterm(15, None)):
            with self.assertRaises(SystemExit):
                self._run(fake)
        self.assertUnlocked(fake)
        self.assertEqual(fake.states[self.top], "Todo")

    def test_timeout_stays_under_lock_ttl(self):
        self.assertLess(dispatch.CLAUDE_TIMEOUT_S, sel.LOCK_TTL.total_seconds())


if __name__ == "__main__":
    unittest.main()
