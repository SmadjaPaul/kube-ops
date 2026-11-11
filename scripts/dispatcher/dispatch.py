#!/usr/bin/env python3
"""Deterministic Linear dispatcher (PLT-197, D-12/D-13/D-20).

Picks one ticket for a lane without any LLM, locks it with wip:claude-<lane>,
then runs a single bounded `claude -p` session and writes a checkpoint.

Usage:
  doppler run -- python3 scripts/dispatcher/dispatch.py --lane local [--dry-run]
  python3 scripts/dispatcher/dispatch.py --lane local --dry-run --snapshot FILE

Concurrency: after posting its lock, the dispatcher re-reads the lane's
wip:claude-<lane> tickets; if another locked ticket sorts before its own
(updatedAt, identifier), it removes its lock and exits. Remaining limit: Linear
has no compare-and-set, so two dispatchers that pick the SAME ticket at the
same moment both see a single lock and both run. Run one dispatcher per lane
(one scheduler entry) to stay out of that window.

Environment:
  LINEAR_API_KEY   Linear API key (names only in Git; value from Doppler).
  DISPATCH_PERMISSION_MODE  claude --permission-mode (default: auto).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import selection as sel  # noqa: E402

API_URL = "https://api.linear.app/graphql"
CLAUDE_TIMEOUT_S = 2 * 60 * 60 + 45 * 60  # 2 h 45: stays under the 3 h lock TTL

ISSUE_FIELDS = """
  id identifier title url priority createdAt updatedAt
  team { key }
  state { name type }
  project { name }
  labels { nodes { id name } }
  inverseRelations(first: 50) { nodes { type issue { identifier state { type } } } }
  comments(first: 50) { nodes { createdAt } }
"""

ISSUES_QUERY = (
    "query($filter: IssueFilter, $after: String) {"
    " issues(filter: $filter, first: 50, after: $after) {"
    " pageInfo { hasNextPage endCursor } nodes {" + ISSUE_FIELDS + "} } }"
)

PROMPT = """Ticket Linear {ident} (voie {lane}). Session neuve, une seule tâche.
Lis le ticket et tous ses commentaires dans Linear, puis AGENTS.md et la skill citée.
Critères : ceux du ticket ; une branche, une PR, checks listés dans la PR ; aucun autre ticket.
Si une action exige Paul : label Needs-operator, commentaire, arrêt.
Sortie en 5 lignes : PR, état du ticket, checks, blocage éventuel, suite."""


class DispatchError(RuntimeError):
    pass


# --- Linear client ---------------------------------------------------------
class Linear:
    def __init__(self, key: str):
        self.auth = key if key.startswith("lin_api_") else f"Bearer {key}"

    def gql(self, query: str, variables: dict | None = None) -> dict:
        body = json.dumps({"query": query, "variables": variables or {}}).encode()
        req = urllib.request.Request(
            API_URL,
            data=body,
            headers={"Content-Type": "application/json", "Authorization": self.auth},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as exc:
            raise DispatchError(f"Linear HTTP {exc.code}: {exc.read()[:300]!r}") from exc
        if payload.get("errors"):
            raise DispatchError(f"Linear GraphQL: {payload['errors'][0].get('message')}")
        return payload["data"]

    def issues(self, flt: dict) -> list[dict]:
        out, after = [], None
        while True:
            page = self.gql(ISSUES_QUERY, {"filter": flt, "after": after})["issues"]
            out.extend(page["nodes"])
            if not page["pageInfo"]["hasNextPage"]:
                return out
            after = page["pageInfo"]["endCursor"]

    def queue(self) -> list[dict]:
        return self.issues({
            "team": {"key": {"eq": sel.TEAM_KEY}},
            "state": {"name": {"eq": sel.READY_STATE}},
            "labels": {"some": {"name": {"eq": sel.READY_LABEL}}},
        })

    def locked(self, lane: str) -> list[dict]:
        return self.issues({
            "team": {"key": {"eq": sel.TEAM_KEY}},
            "labels": {"some": {"name": {"eq": sel.lock_label(lane)}}},
        })

    def label_id(self, name: str) -> str:
        q = "query($n: String!) { issueLabels(filter: {name: {eq: $n}}) { nodes { id } } }"
        nodes = self.gql(q, {"n": name})["issueLabels"]["nodes"]
        if not nodes:
            raise DispatchError(f"label Linear absent : {name}")
        return nodes[0]["id"]

    def state_id(self, name: str) -> str:
        q = ("query($k: String!) { teams(filter: {key: {eq: $k}}) {"
             " nodes { states { nodes { id name } } } } }")
        teams = self.gql(q, {"k": sel.TEAM_KEY})["teams"]["nodes"]
        for state in teams[0]["states"]["nodes"] if teams else []:
            if state["name"] == name:
                return state["id"]
        raise DispatchError(f"statut Linear absent : {name}")

    def add_label(self, issue_id: str, label_id: str) -> None:
        self.gql("mutation($i: String!, $l: String!) { issueAddLabel(id: $i, labelId: $l) { success } }",
                 {"i": issue_id, "l": label_id})

    def remove_label(self, issue_id: str, label_id: str) -> None:
        self.gql("mutation($i: String!, $l: String!) { issueRemoveLabel(id: $i, labelId: $l) { success } }",
                 {"i": issue_id, "l": label_id})

    def set_state(self, issue_id: str, state_id: str) -> None:
        self.gql("mutation($i: String!, $s: String!) { issueUpdate(id: $i, input: {stateId: $s}) { success } }",
                 {"i": issue_id, "s": state_id})

    def comment(self, issue_id: str, body: str) -> None:
        self.gql("mutation($i: String!, $b: String!) { commentCreate(input: {issueId: $i, body: $b}) { success } }",
                 {"i": issue_id, "b": body})


# --- claude -p --------------------------------------------------------------
def claude_command(issue: dict, lane: str) -> list[str]:
    prof = sel.model_profile(issue)
    cmd = [
        "claude", "-p",
        "--model", prof["model"],
        "--effort", prof["effort"],
        "--max-turns", str(prof["max_turns"]),
        "--max-budget-usd", f"{prof['budget_usd']:.2f}",
        "--output-format", "json",
    ]
    mode = os.environ.get("DISPATCH_PERMISSION_MODE", "auto")
    if mode:
        cmd += ["--permission-mode", mode]
    cmd.append(PROMPT.format(ident=issue["identifier"], lane=lane))
    return cmd


def summarize_run(returncode: int, stdout: str, stderr: str) -> dict:
    """Parse `claude -p --output-format json`; never raises."""
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        data = {}
    usage = data.get("usage") or {}
    subtype = data.get("subtype") or ("success" if returncode == 0 else "error")
    ok = returncode == 0 and bool(data) and not data.get("is_error") and subtype == "success"
    cause = None
    if not ok:
        # Never copy raw stderr into Linear: it may carry tokens or URLs.
        cause = subtype if data else f"exit {returncode}, stderr: {len((stderr or '').encode())} octets"
    return {
        "ok": ok,
        "cause": cause,
        "subtype": subtype,
        "result": (data.get("result") or "").strip(),
        "num_turns": data.get("num_turns"),
        "cost_usd": data.get("total_cost_usd"),
        "tokens_in": usage.get("input_tokens", 0),
        "tokens_out": usage.get("output_tokens", 0),
        "cache_read": usage.get("cache_read_input_tokens", 0),
        "cache_write": usage.get("cache_creation_input_tokens", 0),
    }


def checkpoint_body(issue: dict, lane: str, run: dict) -> str:
    prof = sel.model_profile(issue)
    cost = "n/a" if run["cost_usd"] is None else f"{run['cost_usd']:.4f} USD"
    lines = [
        f"**Checkpoint dispatcher** (voie {lane}, {prof['model']}/{prof['effort']}, "
        f"max {prof['max_turns']} tours, budget {prof['budget_usd']:.2f} USD)",
        f"- Issue : {'succès' if run['ok'] else 'échec — ' + str(run['cause'])}",
        f"- Tours : {run['num_turns']}",
        f"- Tokens : entrée {run['tokens_in']}, sortie {run['tokens_out']}, "
        f"cache lu {run['cache_read']}, cache écrit {run['cache_write']}",
        f"- Coût estimé : {cost}",
    ]
    if run["result"]:
        lines += ["", "\n".join(run["result"].splitlines()[:5])]
    if not run["ok"]:
        lines += ["", "Ticket remis en Todo par le dispatcher ; verrou retiré."]
    return "\n".join(lines)


# --- Orchestration ------------------------------------------------------------
def describe(issue: dict) -> str:
    project = (issue.get("project") or {}).get("name") or "sans projet"
    return f"{issue['identifier']} [{project}, prio {issue.get('priority') or 0}] {issue['title']}"


def load_snapshot(path: str) -> tuple[list[dict], list[dict]]:
    data = json.loads(Path(path).read_text())
    return data.get("queue", []), data.get("locked", [])


def run(args: argparse.Namespace, linear: "Linear | None" = None) -> int:
    lane, lock = args.lane, sel.lock_label(args.lane)
    now = sel.utcnow()
    if args.snapshot:
        if not args.dry_run:
            raise DispatchError("--snapshot n'est accepté qu'avec --dry-run")
        queue, locked = load_snapshot(args.snapshot)
    else:
        if linear is None:
            key = os.environ.get("LINEAR_API_KEY")
            if not key:
                raise DispatchError("LINEAR_API_KEY absent : lancer via `doppler run` (nom seul dans Git)")
            linear = Linear(key)
        locked, queue = linear.locked(lane), linear.queue()

    prefix = "[dry-run] " if args.dry_run else ""
    active, expired = sel.classify_locks(locked, now)
    for issue in expired:
        print(f"{prefix}verrou expiré (> 3 h sans commentaire) : {issue['identifier']} -> retrait, retour en Todo")
        if linear and not args.dry_run:
            linear.remove_label(issue["id"], linear.label_id(lock))
            linear.set_state(issue["id"], linear.state_id(sel.READY_STATE))
            linear.comment(issue["id"], f"Verrou `{lock}` retiré par le dispatcher : aucun commentaire "
                                        "depuis plus de 3 h (D-12). Ticket remis en Todo.")

    eligible, rejected = sel.select(queue, lane)
    for issue, reason in rejected:
        print(f"écarté : {issue['identifier']} ({reason})")
    if not eligible:
        print(f"file vide pour la voie {lane}")
        return 0
    issue = eligible[0]
    cmd = claude_command(issue, lane)
    print(f"choisi : {describe(issue)}")
    print("commande : " + " ".join(cmd[:-1]) + " '<prompt>'")

    if active:
        held = ", ".join(i["identifier"] for i in active)
        print(f"voie {lane} occupée par {held} : aucun verrou posé, aucune exécution")
        return 0
    if args.dry_run:
        print(f"[dry-run] poserait {lock}, passerait {issue['identifier']} In Progress, lancerait claude -p")
        return 0
    return execute(linear, issue, lane, cmd)


def lost_race(locked: list[dict], mine: str) -> str | None:
    """Return the identifier of an older lock on the lane, if any."""
    def key(i):
        return (sel.parse_ts(i.get("updatedAt") or i["createdAt"]), i["identifier"])
    others = [i for i in locked if i["identifier"] != mine]
    ours = [i for i in locked if i["identifier"] == mine]
    if not others:
        return None
    if not ours:
        return min(others, key=key)["identifier"]
    first = min(locked, key=key)
    return None if first["identifier"] == mine else first["identifier"]


def execute(linear: "Linear", issue: dict, lane: str, cmd: list[str]) -> int:
    lock = sel.lock_label(lane)
    lock_id = linear.label_id(lock)
    linear.add_label(issue["id"], lock_id)
    result = None
    try:
        winner = lost_race(linear.locked(lane), issue["identifier"])
        if winner:
            print(f"course perdue : {winner} tient déjà {lock} ; verrou retiré, sortie")
            return 0
        linear.set_state(issue["id"], linear.state_id("In Progress"))
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=CLAUDE_TIMEOUT_S, check=False)
            result = summarize_run(proc.returncode, proc.stdout, proc.stderr)
        except (OSError, subprocess.TimeoutExpired) as exc:
            result = summarize_run(-1, "", "")
            result["cause"] = type(exc).__name__
        if not result["ok"]:
            linear.set_state(issue["id"], linear.state_id(sel.READY_STATE))
        linear.comment(issue["id"], checkpoint_body(issue, lane, result))
    except BaseException as exc:  # KeyboardInterrupt included: hand the ticket back
        try:
            linear.set_state(issue["id"], linear.state_id(sel.READY_STATE))
            linear.comment(issue["id"], f"Dispatcher interrompu ({type(exc).__name__}) ; "
                                        "ticket remis en Todo, verrou retiré.")
        except Exception:  # noqa: BLE001 - best effort, the lock removal below matters most
            pass
        raise
    finally:
        linear.remove_label(issue["id"], lock_id)
    print(f"{issue['identifier']} : {'succès' if result['ok'] else 'échec ' + str(result['cause'])}, "
          f"{result['num_turns']} tours, coût {result['cost_usd']}")
    return 0 if result["ok"] else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Dispatcher Linear déterministe (D-12/D-20)")
    parser.add_argument("--lane", choices=sel.LANES, required=True)
    parser.add_argument("--dry-run", action="store_true", help="lecture seule : aucun verrou, aucune exécution")
    parser.add_argument("--snapshot", help="JSON {queue, locked} au format GraphQL, au lieu de l'API (dry-run)")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except DispatchError as exc:
        print(f"dispatch: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
