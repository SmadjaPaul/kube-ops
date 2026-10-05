# Paperclip backlog import plan

This plan is intentionally preparatory. It does not approve the CLI auth
challenge, import the company package, read the live backlog or create runtime
state.

## Preconditions

1. A human confirms the Paperclip instance and target company/project.
2. The canonical `company/` package is reviewed independently.
3. The challenge is confirmed through a safe metadata read. Approval is never
   performed by this R1 change.
4. `backlog-seed.yaml` passes static validation, its `externalId` set is
   unique, and its `backlogIssues` remain non-executable.

## Import sequence

1. Use Paperclip's supported company import preview for the canonical package.
2. Inspect the preview's project and issue inventory without accepting it.
3. Reconcile the preview with `backlog-seed.yaml` by `externalId`, not by title.
4. If any external ID already exists with different immutable meaning, stop
   and report a collision. Do not use replace/overwrite semantics.
5. Create only missing records in the human-approved target project.
6. Keep all epics in `backlog` and all initial issues in `todo`; do not assign,
   start, complete or delegate anything during seed import.
7. Record the resulting Paperclip IDs in a later reconciliation report. This
   Git change must not contain those runtime IDs because the import has not
   happened.

## Idempotence strategy

- The idempotence key is `(project.slug, externalId)`.
- `externalId` values are stable across title or description edits.
- `seedVersion` is metadata, not a new identity namespace.
- Existing matching records are preserved; the importer may report them as
  `already_present` but must not replace them.
- A same-ID/different-content collision is a hard stop requiring human review.
- Re-running a successful import therefore creates zero duplicate records.

## Explicit non-goals

- No live backlog import in this R1 change.
- No company import in this R1 change.
- No challenge approval or board-token creation.
- No credentials, secrets, Kubernetes mutation or product-intent inference.

## Seed v2 deferred work

Seed v2 contains `LLM-010`, a `backlog`/`EXECUTE` record for removing the
remaining Perplexica LiteLLM master-key consumer. Its canonical priority is
`P1`; any Paperclip adapter must map that explicitly to its supported priority
vocabulary. Credential provisioning and execution remain R2/human-only.
