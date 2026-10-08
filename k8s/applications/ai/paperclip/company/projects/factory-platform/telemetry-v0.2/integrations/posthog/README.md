# PostHog raw-event ingress

This integration is the narrow PostHog ingress contract for telemetry v0.2. It
uses a PostHog destination webhook, so new events can be forwarded without a
polling cursor or a second export datastore. The normalizer is deliberately
dependency-light and does not perform HTTP, persist files, or read credentials.

PostHog documents destination webhooks as a way to send event data to any HTTP
endpoint. Its API overview recommends batch exports for regular event exports,
so this adapter is intentionally scoped to the real-time webhook path rather
than pretending that a query API is a durable incremental-export mechanism.

Primary references:

- <https://posthog.com/docs/cdp/destinations/webhook>
- <https://posthog.com/docs/api>

## Record contract

`normalizer.py` converts one webhook event into the existing `raw.events` row
shape, documented by [raw-event.schema.json](raw-event.schema.json). The row
uses a deterministic UUID and contains only the minimum normalized fields
needed at the raw boundary:

- `source`: `posthog`, with `event_type=posthog.event_captured`;
- `aggregate_id` and `dedupe_key`: deterministic source-scoped identity;
- `occurred_at` and `observed_at`: source and collector timestamps;
- `payload.source_id` and `payload.source_event_id`: configured source and
  PostHog `uuid`, `event_uuid`, or `id` when present;
- `payload.idempotency`: the source-scoped key and strategy for at-least-once
  delivery;
- `payload.provenance`: source system, transport, collector, and source event
  ID;
- `payload.raw`: a content hash, byte length, media type, capture time,
  redaction state, and caller-supplied immutable evidence URI;
- `payload.properties`: the source properties with common credential-shaped
  keys redacted.

If PostHog does not provide a stable event identifier, the SHA-256 of the
sanitized source representation is used as both `source_event_id` and the
dedupe basis. The adapter never silently uses a timestamp or event name as an
ID, since those are not unique. The raw-events idempotency boundary remains
`(source, dedupe_key)`.

The adapter does not write the `raw.storage_ref`; the caller must persist the
sanitized bytes in its own content-addressed evidence store and pass the URI to
`normalize_event`. No API tokens, webhook secrets, or other credentials belong
in the payload or evidence bytes.

Run the deterministic fixture tests with:

```sh
python3 tests/test_normalizer.py
```
