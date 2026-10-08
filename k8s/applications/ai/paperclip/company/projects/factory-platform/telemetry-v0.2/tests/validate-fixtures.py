#!/usr/bin/env python3
"""Validate telemetry v0.2 examples and invariants not expressible in JSON Schema."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path
from uuid import UUID

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ModuleNotFoundError:  # pragma: no cover - exercised on minimal operator hosts
    Draft202012Validator = None
    FormatChecker = None


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schema" / "event-envelope.schema.json"
EXAMPLES_PATH = ROOT / "examples" / "events.json"
TEST_RUN_EXAMPLES_PATH = ROOT / "examples" / "test-run-events.json"
INVALID_PATH = ROOT / "tests" / "fixtures" / "invalid-missing-raw.json"

EXPECTED_EXAMPLE_TYPES = {
    "task.created",
    "agent_run.started",
    "model.invoked",
    "tool_call.completed",
    "subagent_call.completed",
    "human_intervention.requested",
    "pr.opened",
    "review.submitted",
    "ci.completed",
    "merge.completed",
    "argo_sync.completed",
    "runtime_acceptance.completed",
    "incident.opened",
    "recovery.completed",
    "rework.detected",
    "cost.recorded",
}


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


EVENT_DATA_REQUIRED = {
    "task.created": {"task_id", "status", "title", "task_kind"},
    "task.completed": {"task_id", "status"},
    "agent_run.started": {"run_id", "task_id", "agent_id", "status"},
    "agent_run.completed": {"run_id", "task_id", "agent_id", "status"},
    "model.invoked": {"invocation_id", "run_id", "provider", "model", "operation", "status"},
    "tool_call.completed": {"tool_call_id", "run_id", "tool_name", "status", "attempt"},
    "subagent_call.completed": {"call_id", "parent_run_id", "child_run_id", "agent_id", "status"},
    "human_intervention.requested": {"intervention_id", "task_id", "reason", "status"},
    "human_intervention.resolved": {"intervention_id", "status", "actor_type"},
    "pr.opened": {"pr_id", "repository", "number", "url", "head_sha", "base_ref"},
    "review.submitted": {"review_id", "pr_id", "verdict", "reviewer_type", "commit_sha"},
    "ci.completed": {"check_id", "repository", "workflow", "status", "commit_sha"},
    "merge.completed": {"pr_id", "merge_commit_sha", "method", "merged_by"},
    "argo_sync.completed": {"application", "desired_revision", "sync_status", "health_status", "operation_id"},
    "runtime_acceptance.completed": {"acceptance_id", "target", "evidence_level", "result", "evidence_refs"},
    "incident.opened": {"incident_id", "severity", "summary", "status"},
    "recovery.completed": {"recovery_id", "incident_id", "action", "result"},
    "rework.detected": {"rework_id", "task_id", "reason", "source_event_ids"},
    "cost.recorded": {"cost_id", "currency", "amount", "basis"},
    "test_run.completed": {"test_run_id", "task_id", "run_id", "attempt", "repository", "commit_sha", "execution_source", "status", "classification"},
}


def validate_fallback(event: dict, label: str) -> None:
    required = {
        "contract", "spec_version", "event_id", "event_type", "tenant_id", "entity",
        "dedupe", "occurred_at", "observed_at", "producer", "provenance", "raw", "data",
    }
    missing = required - event.keys()
    assert not missing, f"{label} missing envelope fields: {sorted(missing)}"
    assert event["contract"] == "factory.telemetry", f"{label} has wrong contract"
    assert event["spec_version"] == "0.2", f"{label} has wrong spec_version"
    assert event["event_type"] in EVENT_DATA_REQUIRED, f"{label} has unknown event_type"
    assert isinstance(event["entity"], dict) and {"type", "id"} <= event["entity"].keys()
    assert isinstance(event["dedupe"], dict) and {"key", "strategy", "scope"} <= event["dedupe"].keys()
    assert isinstance(event["producer"], dict) and {"name", "version", "environment"} <= event["producer"].keys()
    assert isinstance(event["provenance"], dict) and {"source_system", "source_kind", "collector_id"} <= event["provenance"].keys()
    assert isinstance(event["raw"], dict) and {
        "immutable", "content_sha256", "media_type", "byte_length", "storage_ref", "redaction", "captured_at"
    } <= event["raw"].keys(), f"{label} has incomplete raw evidence"
    assert EVENT_DATA_REQUIRED[event["event_type"]] <= event["data"].keys(), f"{label} has incomplete data"


def validate_one(validator, event: dict, label: str) -> None:
    if validator is None:
        validate_fallback(event, label)
        return
    errors = sorted(validator.iter_errors(event), key=lambda error: list(error.path))
    if errors:
        rendered = "\n".join(f"  - {error.json_path}: {error.message}" for error in errors)
        raise AssertionError(f"{label} failed schema validation:\n{rendered}")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    examples = load_json(EXAMPLES_PATH)
    test_run_examples = load_json(TEST_RUN_EXAMPLES_PATH)
    validator = (
        Draft202012Validator(schema, format_checker=FormatChecker())
        if Draft202012Validator is not None
        else None
    )

    assert isinstance(examples, list) and examples, "examples must be a non-empty array"
    seen_event_ids: set[str] = set()
    seen_dedupe_keys: set[tuple[str, str, str, str]] = set()
    seen_types: set[str] = set()

    for index, event in enumerate(examples):
        label = f"examples[{index}]"
        validate_one(validator, event, label)
        event_id = str(UUID(event["event_id"]))
        assert event_id not in seen_event_ids, f"duplicate event_id: {event_id}"
        seen_event_ids.add(event_id)

        provenance = event["provenance"]
        dedupe = event["dedupe"]
        dedupe_tuple = (
            event["tenant_id"],
            provenance["source_system"],
            dedupe["scope"],
            dedupe["key"],
        )
        assert dedupe_tuple not in seen_dedupe_keys, f"duplicate dedupe tuple: {dedupe_tuple}"
        seen_dedupe_keys.add(dedupe_tuple)

        assert parse_time(event["observed_at"]) >= parse_time(event["occurred_at"]), (
            f"observed_at precedes occurred_at in {label}"
        )
        seen_types.add(event["event_type"])

    assert seen_types == EXPECTED_EXAMPLE_TYPES, (
        f"example coverage mismatch: missing={EXPECTED_EXAMPLE_TYPES - seen_types}, "
        f"unexpected={seen_types - EXPECTED_EXAMPLE_TYPES}"
    )

    test_run_ids: set[str] = set()
    test_run_identity: set[tuple[str, str, int, str, str, int | None]] = set()
    for index, event in enumerate(test_run_examples):
        label = f"test-run-examples[{index}]"
        validate_one(validator, event, label)
        data = event["data"]
        test_run_ids.add(data["test_run_id"])
        identity = (data["task_id"], data["run_id"], data["attempt"], data["repository"], data["commit_sha"], data.get("pr_number"))
        assert identity not in test_run_identity, f"duplicate test-run identity: {identity}"
        test_run_identity.add(identity)
        assert data["execution_source"] in {"local", "github_actions"}
        assert data["classification"] in {"functional", "infrastructure", "flake", "policy", "unknown", "unclassified"}
        if data["execution_source"] == "github_actions":
            assert data.get("workflow_run_id") and data.get("workflow")
        if data["execution_source"] == "local":
            assert "workflow_run_id" not in data
    assert {event["data"]["execution_source"] for event in test_run_examples} == {"local", "github_actions"}
    assert {event["data"]["classification"] for event in test_run_examples} >= {"unknown", "unclassified"}

    invalid = load_json(INVALID_PATH)
    if validator is None:
        try:
            validate_fallback(invalid, "invalid fixture")
        except AssertionError:
            pass
        else:
            raise AssertionError("invalid fixture unexpectedly passed fallback validation")
    else:
        invalid_errors = list(validator.iter_errors(invalid))
        assert invalid_errors, "invalid fixture unexpectedly passed schema validation"

    mode = "Draft 2020-12 + invariants" if validator is not None else "fallback structure + invariants (jsonschema unavailable)"
    print(f"validated {len(examples) + len(test_run_examples)} valid events and 1 rejected invalid fixture [{mode}]")
    print("event types: " + ", ".join(sorted(seen_types)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
