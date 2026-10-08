"""Deterministic Stream D facts and denominator-safe KPI mart."""

from __future__ import annotations

from collections import Counter
from typing import Any, Iterable, Mapping

from adapters import UNCLASSIFIED, UNKNOWN


def build_facts(events: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Apply the event idempotency boundary, preserving first-seen evidence."""
    seen: set[tuple[str, str, str, int]] = set()
    facts = []
    for event in events:
        data = event["data"]
        key = (str(event["tenant_id"]), str(event["source"]), str(event["idempotency_key"]), int(event["schema"]["version"]))
        if key in seen:
            continue
        seen.add(key)
        tests = data["tests"]
        classified = [row for row in tests if row["classification"] != UNCLASSIFIED]
        facts.append({"tenant_id": event["tenant_id"], "source": event["source"], "event_id": event["event_id"], "idempotency_key": event["idempotency_key"], "task_id": data["task_id"], "run_id": data["run_id"], "attempt": data["attempt"], "repository": data["repository"], "sha": data["sha"], "pr": data["pr"], "work_item_id": data["work_item_id"], "agent_run_id": data["agent_run_id"], "outcome": data["outcome"], "tests": tests, "classified_test_count": len(classified), "unclassified_test_count": len(tests) - len(classified)})
    return facts


def build_mart(facts: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    rows = list(facts)
    known_runs = [row for row in rows if row["outcome"] in {"passed", "failed", "cancelled"}]
    successful = [row for row in known_runs if row["outcome"] == "passed"]
    tests = [test for row in rows for test in row["tests"] if test["classification"] != UNCLASSIFIED]
    passed = [test for test in tests if test["classification"] == "PASSED"]
    covered = [row for row in rows if row["repository"] != UNKNOWN and row["sha"] != UNKNOWN]
    return {"run_count": len(rows), "known_run_count": len(known_runs), "successful_run_count": len(successful), "unknown_or_unclassified_run_count": sum(row["outcome"] == "unknown" or row["unclassified_test_count"] > 0 for row in rows), "classified_test_count": len(tests), "passed_test_count": len(passed), "covered_run_count": len(covered), "run_success_rate": len(successful) / len(known_runs) if known_runs else None, "test_pass_rate": len(passed) / len(tests) if tests else None, "coverage_rate": len(covered) / len(rows) if rows else None, "by_source": dict(Counter(row["source"] for row in rows))}
