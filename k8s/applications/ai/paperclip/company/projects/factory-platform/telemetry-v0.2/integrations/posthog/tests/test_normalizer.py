#!/usr/bin/env python3
"""Deterministic, dependency-light tests for the PostHog raw-event adapter."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from normalizer import PostHogEventError, normalize_event, normalize_webhook  # noqa: E402


def fixture() -> dict:
    with (Path(__file__).parent / "fixtures" / "webhook-event.json").open(encoding="utf-8") as handle:
        return json.load(handle)


def test_webhook_contract_and_redaction() -> None:
    record = normalize_webhook(
        {"event": fixture()},
        source_id="posthog:factory",
        tenant_id="internal",
        collector_id="posthog-webhook-test",
        raw_storage_ref="s3://factory-raw/posthog/11111111.json",
        observed_at="2026-10-08T08:00:01Z",
    )

    assert record["event_id"] == "2f27c2b1-2230-549b-bf73-5c2ad1a86c1a"
    assert record["source"] == "posthog"
    assert record["event_type"] == "posthog.event_captured"
    assert record["aggregate_type"] == "posthog_event"
    assert record["aggregate_id"] == "posthog:factory:11111111-1111-4111-8111-111111111111"
    assert record["dedupe_key"] == "posthog:posthog:factory:11111111-1111-4111-8111-111111111111"
    assert record["payload"]["source_id"] == "posthog:factory"
    assert record["payload"]["source_event_id"] == fixture()["uuid"]
    assert record["payload"]["idempotency"] == {
        "key": "posthog:factory:11111111-1111-4111-8111-111111111111",
        "strategy": "source_event_id",
        "scope": "source",
    }
    assert record["occurred_at"] == "2026-10-08T08:00:00Z"
    assert record["observed_at"] == "2026-10-08T08:00:01Z"
    assert record["payload"]["provenance"]["source_kind"] == "webhook"
    assert record["payload"]["raw"]["redaction"] == "partial"
    assert record["payload"]["raw"]["immutable"] is True
    assert record["payload"]["event_name"] == "factory_task_completed"
    assert record["payload"]["properties"]["api_key"] == "[REDACTED]"
    assert record["payload"]["properties"]["nested"]["password"] == "[REDACTED]"


def test_raw_digest_is_digest_of_sanitized_evidence() -> None:
    event = fixture()
    record = normalize_event(
        event,
        source_id="posthog:factory",
        tenant_id="internal",
        collector_id="fixture",
        raw_storage_ref="s3://factory-raw/posthog/fixture.json",
        observed_at="2026-10-08T08:00:01Z",
    )
    sanitized = dict(event)
    sanitized["properties"] = {
        **event["properties"],
        "api_key": "[REDACTED]",
        "nested": {"password": "[REDACTED]"},
    }
    raw_bytes = json.dumps(sanitized, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    assert record["payload"]["raw"]["content_sha256"] == hashlib.sha256(raw_bytes).hexdigest()
    assert record["payload"]["raw"]["byte_length"] == len(raw_bytes)


def test_content_hash_fallback_is_stable_and_explicit() -> None:
    event = {
        "event": "anonymous_event",
        "timestamp": "2026-10-08T08:00:00Z",
        "properties": {"value": 1},
    }
    first = normalize_event(
        event,
        source_id="posthog:factory",
        tenant_id="internal",
        collector_id="fixture",
        raw_storage_ref="s3://factory-raw/posthog/anonymous.json",
        observed_at="2026-10-08T08:00:01Z",
    )
    second = normalize_event(
        event,
        source_id="posthog:factory",
        tenant_id="internal",
        collector_id="fixture",
        raw_storage_ref="s3://factory-raw/posthog/anonymous.json",
        observed_at="2026-10-08T08:00:01Z",
    )
    assert first["payload"]["source_event_id"] == second["payload"]["source_event_id"]
    assert first["payload"]["idempotency"]["strategy"] == "content_hash"
    assert len(first["payload"]["source_event_id"]) == 64


def test_invalid_event_does_not_get_a_synthetic_timestamp() -> None:
    try:
        normalize_event(
            {"uuid": "event-1", "event": "missing-time", "properties": {}},
            source_id="posthog:factory",
            tenant_id="internal",
            collector_id="fixture",
            raw_storage_ref="s3://factory-raw/posthog/event-1.json",
            observed_at="2026-10-08T08:00:01Z",
        )
    except PostHogEventError as error:
        assert "occurred_at" in str(error)
    else:  # pragma: no cover - assertion documents the contract
        raise AssertionError("missing source time unexpectedly passed")


if __name__ == "__main__":
    tests = [
        test_webhook_contract_and_redaction,
        test_raw_digest_is_digest_of_sanitized_evidence,
        test_content_hash_fallback_is_stable_and_explicit,
        test_invalid_event_does_not_get_a_synthetic_timestamp,
    ]
    for test in tests:
        test()
    print(f"passed {len(tests)} PostHog normalizer tests")
