from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from adapters import normalize  # noqa: E402
from pipeline import build_facts, build_mart  # noqa: E402


def load_events() -> list[dict]:
    fixture = json.loads((ROOT / "fixtures/source-events.json").read_text())
    return [normalize(item["source"], item["payload"]) for item in fixture]


def test_all_adapters_emit_canonical_correlation_and_provenance() -> None:
    events = load_events()
    assert {event["source"] for event in events} == {"local", "github", "elementary"}
    for event in events:
        assert event["event_type"] == "factory.test_run.completed"
        assert event["schema"] == {"id": "factory.test_run", "version": 1}
        assert event["idempotency_key"]
        assert event["provenance"]["adapter"] == event["source"]
        assert all(event["data"][key] for key in ("task_id", "run_id", "repository", "sha", "pr", "work_item_id", "agent_run_id"))


def test_unknowns_are_retained_and_denominators_are_safe() -> None:
    events = load_events()
    mart = build_mart(build_facts(events))
    assert mart["run_count"] == 4
    assert mart["unknown_or_unclassified_run_count"] == 2
    assert mart["known_run_count"] == 2
    assert mart["run_success_rate"] == 0.5
    assert mart["test_pass_rate"] == 0.5
    assert mart["coverage_rate"] == 0.5
    empty = build_mart([])
    assert empty["run_success_rate"] is None
    assert empty["test_pass_rate"] is None
    assert empty["coverage_rate"] is None


def test_idempotency_deduplicates_facts_but_not_source_evidence() -> None:
    events = load_events()
    duplicate = json.loads(json.dumps(events[0]))
    duplicate["event_id"] = "delivery-retry"
    events.append(duplicate)
    facts = build_facts(events)
    assert len(events) == 5
    assert len(facts) == 4
