#!/usr/bin/env python3
"""PLT-562: offline tests of scripts/optio/triage.py (fake Linear, Optio, GitHub and claude).

The real dispatch selector runs, so what the triage labels is what the dispatch accepts.
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import stat
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("triage", ROOT / "scripts/optio/triage.py")
triage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(triage)
NOW = dt.datetime(2026, 11, 27, 12, 0, tzinfo=dt.timezone.utc)
OLD = "2026-11-26T08:00:00.000Z"
LABELS = ["wip:optio", "wip:claude-abc", "Needs-operator", "Attend:décision", "Attend:tiers", "Intake", "J5", "agents"]


def issue(identifier, state="unstarted", labels=(), description="Corriger le test.", **extra):
    team = identifier.split("-")[0]
    base = {
        "id": "id-" + identifier, "identifier": identifier, "title": "Titre " + identifier,
        "description": description, "priority": 3, "createdAt": OLD, "startedAt": OLD, "url": "u",
        "team": {"id": "team-" + team, "key": team}, "state": {"id": "s", "type": state, "name": state},
        "labels": {"nodes": [{"id": "l-" + n, "name": n} for n in labels]}, "assignee": None, "parent": None,
        "children": {"nodes": []}, "relations": {"nodes": []}, "inverseRelations": {"nodes": []},
        "attachments": {"nodes": []}, "comments": {"nodes": []},
    }
    base.update(extra)
    return base


def pr(identifier, number=1, kind="closes", repo="website"):
    return {"url": f"https://github.com/SmadjaPaul/{repo}/pull/{number}", "title": f"[{identifier}] x",
            "createdAt": OLD, "updatedAt": OLD, "metadata": {"linkKind": kind} if kind else {}}


class World:
    def __init__(self, issues, tasks=(), prs=None, github=None):
        self.issues, self.tasks, self.prs, self.github = issues, list(tasks), prs or {}, github or {}
        self.writes, self.calls = [], []

    def http(self, method, url, headers, body=None):
        self.calls.append((method, url))
        if url == triage.LINEAR_URL:
            request = json.loads(body)
            query = request["query"]
            if "OptioTriageMeta" in query:
                teams = [{"id": "team-" + k, "key": k, "states": {"nodes": [
                    {"id": k + "-todo", "name": "Todo", "type": "unstarted", "position": 1},
                    {"id": k + "-done", "name": "Done", "type": "completed", "position": 3}]}} for k in ("PLT", "PRD")]
                labels = [{"id": "l-" + n, "name": n, "team": None} for n in LABELS]
                data = {"teams": {"nodes": teams}, "issueLabels": {"nodes": labels}}
            elif "OptioTriage(" in query:
                data = {"issues": {"nodes": self.issues, "pageInfo": {"hasNextPage": False, "endCursor": None}}}
            else:
                name = query.split("{ ")[1].split("(")[0]
                self.writes.append((name, request["variables"]))
                data = {name: {"success": True, "issue": {"id": "n", "identifier": "PLT-900"}}}
            return 200, json.dumps({"data": data})
        if "/api/tasks" in url:
            assert method == "GET"
            return 200, json.dumps({"tasks": self.tasks})
        if "/api/repos" in url:
            return 200, json.dumps({"repos": [{"repoUrl": f"https://github.com/smadjapaul/{r}"}
                                              for r in ("kube-ops", "website", "Atlas")]})
        if "/api/pull-requests/status" in url:
            assert method == "GET"
            number = url.rsplit("%2F", 1)[-1]
            return 200, json.dumps({"prState": self.prs.get(number, "open"), "headSha": "abcdef1234567890"})
        if url.startswith("https://api.github.com/"):
            body_text = self.github.get(url.rsplit("/", 1)[-1])
            return (200, json.dumps({"body": body_text})) if body_text is not None else (404, "{}")
        raise AssertionError("unexpected url " + url)


class TriageTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        fake = self.dir / "claude"
        fake.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" >" + str(self.dir / "argv") +
                        "\nenv >" + str(self.dir / "env") + "\ncat >" + str(self.dir / "stdin") +
                        "\ncat " + str(self.dir / "reply") + "\n")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.env = {"PATH": f"{self.dir}:{os.environ['PATH']}", "LINEAR_INTAKE_KEY": "SECRET-linear",
                    "OPTIO_API_TOKEN": "SECRET-optio", "OPTIO_GATEWAY_URL": "http://gateway",
                    "OPTIO_GATEWAY_KEY": "SECRET-gateway"}

    def run_pass(self, world, verdicts=(), apply=True, extra=()):
        (self.dir / "reply").write_text(json.dumps({
            "result": json.dumps(list(verdicts)), "usage": {"input_tokens": 100, "output_tokens": 10}}))
        argv = ["--select-actions", str(ROOT / "scripts/optio/select-actions.sh"),
                "--instructions", str(ROOT / "docs/operations/optio-triage.md"), *extra]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status = triage.main(argv + (["--apply"] if apply else []), self.env, world.http, NOW)
        self.output = out.getvalue()
        self.assertNotIn("SECRET", self.output)
        self.summary = json.loads(self.output.strip().splitlines()[-1])
        return status

    def names(self, world):
        return [name for name, _ in world.writes]

    def labelled(self, world):
        return [(v["id"], v["label"]) for n, v in world.writes if n == "issueAddLabel"]

    def test_take_adds_repo_line_then_label_and_model_has_no_secret_nor_tool(self):
        world = World([issue("PLT-1")])
        self.assertEqual(0, self.run_pass(world, [{"id": "PLT-1", "verdict": "take", "repo": "kube-ops"}]))
        self.assertEqual(["issueUpdate", "issueAddLabel", "commentCreate"], self.names(world))
        self.assertTrue(world.writes[0][1]["input"]["description"].endswith("Dépôt: kube-ops"))
        self.assertEqual([("id-PLT-1", "l-wip:optio")], self.labelled(world))
        env = (self.dir / "env").read_text()
        self.assertNotIn("SECRET-linear", env)
        self.assertNotIn("SECRET-optio", env)
        argv = (self.dir / "argv").read_text().split("\n")
        self.assertEqual("", argv[argv.index("--tools") + 1])
        self.assertEqual("text/strong", argv[argv.index("--model") + 1])
        self.assertNotIn("SECRET", (self.dir / "argv").read_text())
        self.assertEqual(100, self.summary["input_tokens"])

    def test_dry_run_writes_nothing(self):
        world = World([issue("PLT-1")])
        self.run_pass(world, [{"id": "PLT-1", "verdict": "take", "repo": "kube-ops"}], apply=False)
        self.assertEqual([], world.writes)
        self.assertEqual(1, self.summary["taken"])

    def test_ineligible_tickets_never_reach_the_model(self):
        blocker = {"type": "blocks", "issue": {"identifier": "PLT-9", "state": {"type": "started"}}}
        world = World([
            issue("PLT-2", labels=["Needs-operator"]), issue("PLT-3", assignee={"id": "x"}),
            issue("PLT-4", labels=["wip:claude-abc"]), issue("PLT-5", inverseRelations={"nodes": [blocker]}),
            issue("PLT-6", children={"nodes": [{"state": {"type": "backlog"}}]}), issue("PLT-7", state="started",
                  assignee={"id": "x"}), issue("PLT-8"),
        ], tasks=[{"title": "[PLT-8] déjà fait", "state": "completed"}])
        self.assertEqual(0, self.run_pass(world))
        self.assertEqual(0, self.summary["model_calls"])
        self.assertEqual([], world.writes)

    def test_verdicts_outside_the_rules_are_rejected(self):
        world = World([issue("PLT-1", description="Changer Talos."), issue("PLT-2"),
                       issue("PLT-3", description="x\nDépôt: website")])
        self.run_pass(world, [
            {"id": "PLT-1", "verdict": "take", "repo": "kube-ops"},
            {"id": "PLT-2", "verdict": "take", "repo": "evil-repo"},
            {"id": "PLT-3", "verdict": "take", "repo": "kube-ops"},
            {"id": "PLT-99", "verdict": "take", "repo": "kube-ops"},
            {"id": "PLT-2", "verdict": "delete"},
        ])
        self.assertEqual([], world.writes)
        self.assertEqual(5, self.summary["rejected"])

    def test_block_marks_once_with_labels_and_expected_action(self):
        world = World([issue("PLT-1")])
        verdict = {"id": "PLT-1", "verdict": "block", "category": "decision",
                   "reason": "Choix de @paul requis.", "action": "Choisir A ou B."}
        self.run_pass(world, [verdict])
        self.assertEqual([("id-PLT-1", "l-Needs-operator"), ("id-PLT-1", "l-Attend:décision")],
                         self.labelled(world))
        body = world.writes[-1][1]["input"]["body"]
        self.assertIn("Geste attendu : Choisir A ou B.", body)
        self.assertNotIn("@", body)
        # Next pass, even without the labels: the marker stops a second judgement.
        again = World([issue("PLT-1", comments={"nodes": [{"body": body, "createdAt": OLD}]})])
        self.run_pass(again)
        self.assertEqual((0, []), (self.summary["model_calls"], again.writes))
        # An edited description is judged again.
        edited = World([issue("PLT-1", description="Nouveau.", comments={"nodes": [{"body": body, "createdAt": OLD}]})])
        self.run_pass(edited)
        self.assertEqual(1, self.summary["model_calls"])

    def test_take_is_not_replayed_after_the_label_is_removed(self):
        world = World([issue("PLT-1")])
        self.run_pass(world, [{"id": "PLT-1", "verdict": "take", "repo": "kube-ops"}])
        description = world.writes[0][1]["input"]["description"]
        body = world.writes[-1][1]["input"]["body"]
        again = World([issue("PLT-1", description=description,
                             comments={"nodes": [{"body": body, "createdAt": OLD}]})])
        self.run_pass(again)
        self.assertEqual(0, self.summary["model_calls"])

    def test_full_queue_costs_no_model_call(self):
        queued = [issue(f"PLT-{n}", labels=["wip:optio"], description="x\nDépôt: kube-ops") for n in range(10, 12)]
        world = World(queued + [issue("PLT-1")])
        self.run_pass(world, extra=["--stock", "2"])
        self.assertEqual((2, 0), (self.summary["stock_before"], self.summary["model_calls"]))

    def test_stock_bounds_the_takes(self):
        world = World([issue("PLT-1"), issue("PLT-2")])
        self.run_pass(world, [{"id": i, "verdict": "take", "repo": "kube-ops"} for i in ("PLT-1", "PLT-2")],
                      extra=["--stock", "1"])
        self.assertEqual(1, self.summary["taken"])

    def test_split_creates_bounded_subtickets(self):
        world = World([issue("PLT-1", labels=["J5", "agents"])])
        parts = [{"title": f"Lot {n}", "repo": "kube-ops", "description": "Faire.\nDépôt: homelab-infra"}
                 for n in (1, 2)]
        self.run_pass(world, [{"id": "PLT-1", "verdict": "split", "subtickets": parts}])
        created = [v["input"] for n, v in world.writes if n == "issueCreate"]
        self.assertEqual(2, len(created))
        self.assertEqual("id-PLT-1", created[0]["parentId"])
        self.assertEqual(["l-J5", "l-agents", "l-wip:optio"], created[0]["labelIds"])
        self.assertNotIn("homelab-infra", created[0]["description"])
        self.assertEqual("commentCreate", world.writes[0][0])
        too_many = World([issue("PLT-1")])
        self.run_pass(too_many, [{"id": "PLT-1", "verdict": "split", "subtickets": parts * 3}])
        self.assertEqual([], too_many.writes)

    def test_split_cannot_smuggle_a_forbidden_zone(self):
        world = World([issue("PLT-1")])
        parts = [{"title": "Lot", "repo": "kube-ops", "description": "Lire le secret."}] * 2
        self.run_pass(world, [{"id": "PLT-1", "verdict": "split", "subtickets": parts}])
        self.assertEqual([], world.writes)

    def test_merged_ticket_goes_done_with_proof(self):
        world = World([issue("PRD-1", state="started", labels=["wip:optio"], attachments={"nodes": [pr("PRD-1")]})],
                      tasks=[{"title": "[PRD-1] x", "state": "completed"}], prs={"1": "merged"})
        self.run_pass(world)
        self.assertEqual(["commentCreate", "issueUpdate"], self.names(world))
        self.assertEqual({"stateId": "PRD-done"}, world.writes[1][1]["input"])
        self.assertIn("pull/1", world.writes[0][1]["input"]["body"])

    def test_part_of_merge_is_noted_once_and_not_closed(self):
        ticket = issue("PLT-1", state="started", attachments={"nodes": [pr("PLT-1", kind="contributes")]})
        world = World([ticket], prs={"1": "merged"})
        self.run_pass(world)
        self.assertEqual(["commentCreate"], self.names(world))
        ticket["comments"] = {"nodes": [{"body": world.writes[0][1]["input"]["body"], "createdAt": OLD}]}
        again = World([ticket], prs={"1": "merged"})
        self.run_pass(again)
        self.assertEqual([], again.writes)

    def test_public_fixes_line_proves_the_merge_and_part_of_does_not(self):
        for body, expected in (("Fixes PLT-1", 1), ("Fixes PLT-1\nPart of PLT-1", 0), (None, 0)):
            world = World([issue("PLT-1", state="started", attachments={"nodes": [pr("PLT-1", kind=None)]})],
                          prs={"1": "merged"}, github={"1": body} if body else {})
            self.run_pass(world)
            self.assertEqual(expected, self.summary["closed"], body)

    def test_open_pr_or_running_task_keeps_the_ticket(self):
        opened = World([issue("PLT-1", state="started", attachments={"nodes": [pr("PLT-1")]})])
        running = World([issue("PLT-1", state="started")], tasks=[{"title": "[PLT-1] x", "state": "running"}])
        for world in (opened, running):
            self.run_pass(world)
            self.assertEqual([], world.writes)

    def test_orphan_is_released_only_when_stale_and_claimed_or_unassigned(self):
        stale = issue("PLT-1", state="started", labels=["wip:claude-abc"], assignee={"id": "x"})
        fresh = issue("PLT-2", state="started", labels=["wip:claude-abc"],
                      comments={"nodes": [{"body": "avance", "createdAt": "2026-11-27T11:00:00.000Z"}]})
        owned = issue("PLT-3", state="started", assignee={"id": "x"})
        human = issue("PLT-4", state="started", labels=["wip:claude-abc", "Needs-operator"])
        world = World([stale, fresh, owned, human])
        self.run_pass(world)
        self.assertEqual(["commentCreate", "issueUpdate", "issueRemoveLabel"], self.names(world))
        self.assertEqual({"stateId": "PLT-todo", "assigneeId": None}, world.writes[1][1]["input"])

    def test_missing_environment_and_api_error(self):
        del self.env["OPTIO_GATEWAY_KEY"]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, triage.main([], self.env))
        self.env["OPTIO_GATEWAY_KEY"] = "SECRET-gateway"
        world = World([])
        world.http = lambda *a: (500, "boom")
        self.assertEqual(1, self.run_pass(world))
        self.assertEqual(1, self.summary["errors"])


class OrderTest(unittest.TestCase):
    def test_priority_palier_unblocks_age(self):
        unblocking = {"nodes": [{"type": "blocks", "relatedIssue": {"identifier": "X", "state": {"type": "backlog"}}}]}
        tickets = [issue("PLT-4", priority=0), issue("PLT-3", labels=["J5"]),
                   issue("PLT-2", labels=["J5"], relations=unblocking), issue("PLT-1", labels=["J2"])]
        self.assertEqual(["PLT-1", "PLT-2", "PLT-3", "PLT-4"],
                         [i["identifier"] for i in sorted(tickets, key=triage.order_key)])


if __name__ == "__main__":
    unittest.main()
