"""Offline tests for the dispatcher: selection, sort, locks, claude command, JSON parsing.

Run: python3 -m unittest discover -s scripts/dispatcher/tests
No network: the Linear client is never instantiated with a key.
"""

import io
import json
import sys
import unittest
from contextlib import redirect_stdout
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
        self.assertLessEqual(len(cmd[-1].splitlines()), 5)

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
        self.assertIn("boom", run["cause"])


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

    def test_snapshot_requires_dry_run_and_missing_key_fails_cleanly(self):
        snap = str(FIX / "snapshot-2026-11-11.json")
        self.assertEqual(self._run("--lane", "local", "--snapshot", snap)[0], 2)
        self.assertEqual(self._run("--lane", "local", "--dry-run")[0], 2)


if __name__ == "__main__":
    unittest.main()
