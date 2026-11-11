"""Pure queue logic for the Linear dispatcher (D-10, D-12, D-20).

No network, no clock side effects: every function takes plain dicts shaped
like the Linear GraphQL `Issue` nodes fetched by dispatch.py, so it can be
unit-tested from JSON fixtures.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

# --- Routing table (D-12) -------------------------------------------------
# model label -> (claude --model, --effort, --max-turns, --max-budget-usd)
MODEL_TABLE = {
    "agent:haiku": {"model": "haiku", "effort": "low", "max_turns": 8, "budget_usd": 1.0},
    "agent:sonnet": {"model": "sonnet", "effort": "medium", "max_turns": 35, "budget_usd": 5.0},
    "agent:opus": {"model": "opus", "effort": "high", "max_turns": 60, "budget_usd": 15.0},
}

TEAM_KEY = "PLT"
READY_STATE = "Todo"
READY_LABEL = "Agent-ready"
EXCLUDED_LABELS = {"Needs-operator", "Différé", "agent:codex"}
LANES = ("local", "cloud")
LOCK_TTL = timedelta(hours=3)

# D-10 project order; a project matches when its name starts with the entry
# ("Factory" covers "Factory et automatisation"). Unknown projects go last.
PROJECT_ORDER = ("Socle sain", "Factory", "Services famille", "Agent personnel")

DONE_STATE_TYPES = {"completed", "canceled"}


def lock_label(lane: str) -> str:
    return f"wip:claude-{lane}"


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def label_names(issue: dict) -> list[str]:
    return [label["name"] for label in issue.get("labels", {}).get("nodes", [])]


def open_blockers(issue: dict) -> list[str]:
    """Identifiers of issues that block `issue` and are not finished.

    Linear stores "A blocks B" on A; B sees it in inverseRelations with
    type "blocks" and `issue` = A.
    """
    blockers = []
    for rel in issue.get("inverseRelations", {}).get("nodes", []):
        if rel.get("type") != "blocks":
            continue
        blocker = rel.get("issue") or {}
        if (blocker.get("state") or {}).get("type") not in DONE_STATE_TYPES:
            blockers.append(blocker.get("identifier", "?"))
    return blockers


def rejection_reason(issue: dict, lane: str) -> str | None:
    """Return why `issue` is not eligible for `lane`, or None if it is."""
    labels = set(label_names(issue))
    if (issue.get("team") or {}).get("key", TEAM_KEY) != TEAM_KEY:
        return "hors équipe PLT"
    if (issue.get("state") or {}).get("name") != READY_STATE:
        return f"statut {(issue.get('state') or {}).get('name')}"
    if READY_LABEL not in labels:
        return "sans Agent-ready"
    excluded = sorted(labels & EXCLUDED_LABELS)
    if excluded:
        return "label " + ", ".join(excluded)
    models = sorted(labels & MODEL_TABLE.keys())
    if not models:
        return "sans label agent:haiku|sonnet|opus"
    if len(models) > 1:
        return "plusieurs labels agent:* (" + ", ".join(models) + ")"
    if f"exec:{lane}" not in labels:
        return f"pas exec:{lane}"
    if any(name.startswith("wip:") for name in labels):
        return "déjà verrouillé"
    blockers = open_blockers(issue)
    if blockers:
        return "bloqué par " + ", ".join(blockers)
    return None


def project_rank(issue: dict) -> int:
    name = (issue.get("project") or {}).get("name") or ""
    for index, prefix in enumerate(PROJECT_ORDER):
        if name.startswith(prefix):
            return index
    return len(PROJECT_ORDER)


def priority_rank(issue: dict) -> int:
    # Linear: 0 = None, 1 = Urgent ... 4 = Low. None goes last.
    value = issue.get("priority") or 0
    return value if value > 0 else 5


def sort_key(issue: dict) -> tuple:
    return (project_rank(issue), priority_rank(issue), issue["createdAt"], issue["identifier"])


def select(issues: list[dict], lane: str) -> tuple[list[dict], list[tuple[dict, str]]]:
    """Split issues into (eligible sorted by D-10/priority/age, rejected with reasons)."""
    if lane not in LANES:
        raise ValueError(f"voie inconnue : {lane}")
    eligible, rejected = [], []
    for issue in issues:
        reason = rejection_reason(issue, lane)
        if reason is None:
            eligible.append(issue)
        else:
            rejected.append((issue, reason))
    eligible.sort(key=sort_key)
    return eligible, rejected


def model_profile(issue: dict) -> dict:
    (label,) = set(label_names(issue)) & MODEL_TABLE.keys()
    return {"label": label, **MODEL_TABLE[label]}


def last_activity(issue: dict) -> datetime:
    """Most recent comment; falls back to updatedAt when the ticket has none."""
    stamps = [parse_ts(c["createdAt"]) for c in issue.get("comments", {}).get("nodes", [])]
    if stamps:
        return max(stamps)
    return parse_ts(issue.get("updatedAt") or issue["createdAt"])


def classify_locks(locked: list[dict], now: datetime) -> tuple[list[dict], list[dict]]:
    """Split lane-locked issues into (active, expired) per the 3 h rule (D-12)."""
    active, expired = [], []
    for issue in locked:
        (expired if now - last_activity(issue) >= LOCK_TTL else active).append(issue)
    return active, expired


def utcnow() -> datetime:
    return datetime.now(timezone.utc)
