"""Normalize one PostHog destination-webhook event into a raw ingress record.

This module intentionally has no HTTP client, persistence layer, or credential
handling. The caller owns webhook authentication and evidence storage.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any, Mapping
from urllib.parse import urlparse
from uuid import NAMESPACE_URL, uuid5


SOURCE = "posthog"
EVENT_TYPE = "posthog.event_captured"
AGGREGATE_TYPE = "posthog_event"
_SECRET_KEY = re.compile(
    r"(?:^|[_-])(authorization|cookie|password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)(?:$|[_-])",
    re.IGNORECASE,
)


class PostHogEventError(ValueError):
    """Raised when a webhook event cannot satisfy the raw-event contract."""


def _timestamp(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PostHogEventError(f"{field} must be a non-empty ISO-8601 string")
    candidate = value.strip()
    try:
        parsed = datetime.fromisoformat(candidate.replace("Z", "+00:00"))
    except ValueError as error:
        raise PostHogEventError(f"{field} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise PostHogEventError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _redact(value: Any) -> tuple[Any, bool]:
    """Return JSON-safe data with common credential-shaped keys removed."""

    if isinstance(value, Mapping):
        redacted = False
        result: dict[str, Any] = {}
        for key, child in value.items():
            key_text = str(key)
            if _SECRET_KEY.search(key_text):
                result[key_text] = "[REDACTED]"
                redacted = True
                continue
            safe_child, child_redacted = _redact(child)
            result[key_text] = safe_child
            redacted = redacted or child_redacted
        return result, redacted
    if isinstance(value, list):
        children = [_redact(child) for child in value]
        return [child for child, _ in children], any(flag for _, flag in children)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value, False
    raise PostHogEventError(f"unsupported JSON value: {type(value).__name__}")


def _stable_json(value: Mapping[str, Any]) -> bytes:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise PostHogEventError("PostHog event must be JSON serializable") from error


def _source_event_id(event: Mapping[str, Any], raw_bytes: bytes) -> tuple[str, str]:
    for key in ("uuid", "event_uuid", "id"):
        value = event.get(key)
        if value is not None and str(value).strip():
            return str(value).strip(), "source_event_id"
    return hashlib.sha256(raw_bytes).hexdigest(), "content_hash"


def _event_payload(event: Mapping[str, Any]) -> dict[str, Any]:
    event_name = event.get("event", event.get("name"))
    if not isinstance(event_name, str) or not event_name.strip():
        raise PostHogEventError("PostHog event must contain a non-empty event name")

    properties = event.get("properties", {})
    if not isinstance(properties, Mapping):
        raise PostHogEventError("PostHog event properties must be an object")
    safe_properties, _ = _redact(properties)
    payload: dict[str, Any] = {
        "event_name": event_name,
        "properties": safe_properties,
    }
    distinct_id = event.get("distinct_id", properties.get("distinct_id"))
    if distinct_id is not None:
        if not isinstance(distinct_id, str) or not distinct_id:
            raise PostHogEventError("distinct_id must be a non-empty string when present")
        payload["distinct_id"] = distinct_id
    return payload


def normalize_event(
    event: Mapping[str, Any],
    *,
    source_id: str,
    tenant_id: str,
    collector_id: str,
    raw_storage_ref: str,
    observed_at: str,
) -> dict[str, Any]:
    """Build a deterministic ``raw.events`` row from a PostHog webhook event.

    ``raw_storage_ref`` points at the caller's content-addressed evidence
    store. This function computes the digest and metadata but never writes it.
    ``tenant_id`` is accepted as an explicit boundary input and is retained in
    the payload for downstream partitioning. The caller owns inserting the row
    into the tenant-scoped raw-events relation.
    """

    if not isinstance(event, Mapping):
        raise PostHogEventError("event must be an object")
    for name, value in (("source_id", source_id), ("tenant_id", tenant_id), ("collector_id", collector_id)):
        if not isinstance(value, str) or not value.strip():
            raise PostHogEventError(f"{name} must be a non-empty string")
    parsed_ref = urlparse(raw_storage_ref)
    if not parsed_ref.scheme or not parsed_ref.netloc:
        raise PostHogEventError("raw_storage_ref must be an absolute URI")

    safe_event, redacted = _redact(event)
    if not isinstance(safe_event, dict):  # pragma: no cover - _redact preserves mappings
        raise PostHogEventError("event must be an object")
    raw_bytes = _stable_json(safe_event)
    digest = hashlib.sha256(raw_bytes).hexdigest()
    source_event_id, strategy = _source_event_id(safe_event, raw_bytes)
    occurred_value = safe_event.get("timestamp", safe_event.get("occurred_at", safe_event.get("created_at")))
    occurred_at = _timestamp(occurred_value, "occurred_at")
    observed_at = _timestamp(observed_at, "observed_at")
    event_payload = _event_payload(safe_event)
    dedupe_key = f"{SOURCE}:{source_id}:{source_event_id}"
    event_id = str(uuid5(NAMESPACE_URL, f"factory-platform/raw.events/{tenant_id}:{dedupe_key}"))
    payload: dict[str, Any] = {
        "tenant_id": tenant_id,
        "source_id": source_id,
        "source_event_id": source_event_id,
        "event_name": event_payload["event_name"],
        "properties": event_payload["properties"],
        "idempotency": {
            "key": f"{source_id}:{source_event_id}",
            "strategy": strategy,
            "scope": "source",
        },
        "provenance": {
            "source_system": SOURCE,
            "source_kind": "webhook",
            "collector_id": collector_id,
            "source_id": source_id,
            "source_event_id": source_event_id,
        },
        "raw": {
            "immutable": True,
            "content_sha256": digest,
            "media_type": "application/json",
            "byte_length": len(raw_bytes),
            "storage_ref": raw_storage_ref,
            "redaction": "partial" if redacted else "none",
            "captured_at": observed_at,
        },
    }
    if "distinct_id" in event_payload:
        payload["distinct_id"] = event_payload["distinct_id"]
    return {
        "event_id": event_id,
        "source": SOURCE,
        "event_type": EVENT_TYPE,
        "aggregate_type": AGGREGATE_TYPE,
        "aggregate_id": f"{source_id}:{source_event_id}",
        "dedupe_key": dedupe_key,
        "occurred_at": occurred_at,
        "observed_at": observed_at,
        "payload": payload,
    }


def normalize_webhook(
    body: Mapping[str, Any],
    **kwargs: str,
) -> dict[str, Any]:
    """Normalize a direct webhook body or a body wrapped under ``event``."""

    if not isinstance(body, Mapping):
        raise PostHogEventError("webhook body must be an object")
    candidate = body.get("event") if isinstance(body.get("event"), Mapping) else body
    return normalize_event(candidate, **kwargs)
