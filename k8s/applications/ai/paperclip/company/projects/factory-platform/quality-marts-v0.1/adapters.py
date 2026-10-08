"""Normalize supported source results into the Stream D canonical event."""

from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha256
from typing import Any, Mapping

UNKNOWN = "UNKNOWN"
UNCLASSIFIED = "UNCLASSIFIED"
OUTCOMES = {"passed", "failed", "cancelled", "unknown"}
CLASSIFICATIONS = {"PASSED", "FAILED", "SKIPPED", "UNAVAILABLE", "NOT_APPLICABLE", UNCLASSIFIED}


def _value(data: Mapping[str, Any], *keys: str, default: str = UNKNOWN) -> str:
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return str(value)
    return default


def _tests(rows: Any) -> list[dict[str, str]]:
    if not isinstance(rows, list):
        return [{"name": "UNKNOWN", "classification": UNCLASSIFIED}]
    result = []
    for row in rows:
        if not isinstance(row, Mapping):
            continue
        raw = _value(row, "classification", "status", default=UNCLASSIFIED).upper()
        result.append({"name": _value(row, "name", "test", default="UNKNOWN"), "classification": raw if raw in CLASSIFICATIONS else UNCLASSIFIED})
    return result or [{"name": "UNKNOWN", "classification": UNCLASSIFIED}]


def normalize(source: str, payload: Mapping[str, Any], *, tenant_id: str = "internal", observed_at: str = "2026-10-08T00:00:00Z") -> dict[str, Any]:
    """Normalize local, GitHub, or Elementary payloads without source leakage."""
    if source not in {"local", "github", "elementary"}:
        raise ValueError(f"unsupported source: {source}")
    ids = payload.get("identity") if isinstance(payload.get("identity"), Mapping) else payload
    if source == "github":
        ids = {**ids, "repository": ids.get("repository") or ids.get("repo"), "sha": ids.get("sha") or ids.get("head_sha"), "pr": ids.get("pr") or ids.get("pull_request")}
    if source == "elementary":
        ids = {**ids, "run_id": ids.get("run_id") or ids.get("invocation_id"), "repository": ids.get("repository") or ids.get("project")}
    source_event_id = _value(payload, "source_event_id", "id", "workflow_run_id", "invocation_id")
    idempotency = _value(payload, "idempotency_key", default=sha256(f"{tenant_id}:{source}:{source_event_id}".encode()).hexdigest())
    outcome = _value(payload, "outcome", "conclusion", "status", default="unknown").lower()
    outcome = {"success": "passed", "failure": "failed", "neutral": "unknown"}.get(outcome, outcome)
    if outcome not in OUTCOMES:
        outcome = "unknown"
    return {
        "event_id": _value(payload, "event_id", default=f"{source}:{source_event_id}"),
        "event_type": "factory.test_run.completed",
        "schema": {"id": "factory.test_run", "version": 1},
        "tenant_id": tenant_id,
        "source": source,
        "idempotency_key": idempotency,
        "occurred_at": _value(payload, "occurred_at", "completed_at", default=observed_at),
        "observed_at": observed_at,
        "provenance": {"adapter": source, "source_event_id": source_event_id, "collector_version": "stream-d/0.1", **({"workflow_run_id": str(payload["workflow_run_id"])} if payload.get("workflow_run_id") else {})},
        "data": {
            "task_id": _value(ids, "task_id"), "run_id": _value(ids, "run_id"), "attempt": int(ids.get("attempt", 1)),
            "repository": _value(ids, "repository"), "sha": _value(ids, "sha"), "pr": _value(ids, "pr"),
            "work_item_id": _value(ids, "work_item_id", "work_item"), "agent_run_id": _value(ids, "agent_run_id"),
            "outcome": outcome, "tests": _tests(payload.get("tests") or payload.get("test_results")),
        },
    }
