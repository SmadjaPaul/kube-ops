# Paperclip backlog import plan

`backlog-seed.yaml` is the canonical work inventory. It is not a native
Paperclip company-import manifest. The repository-owned adapter at
`scripts/paperclip/import-backlog-seed.mjs` translates it through Paperclip's
supported issue API.

The adapter is dry-run by default. Applying a plan requires both `--apply` and
`--confirm-apply`, a conflict-free plan, and `PAPERCLIP_API_KEY`. It never
deletes issues, creates projects, assigns work, checks out issues, wakes agents
or changes heartbeats.

## Preconditions

1. A human confirms the Paperclip instance and target company/project.
2. The canonical seed and adapter are reviewed independently.
3. The adapter lists the existing company projects and issues read-only.
4. `backlog-seed.yaml` passes static validation and its `externalId` set is
   unique.

## Import sequence

1. List existing projects and issues through the official CLI session or REST
   API.
2. Reconcile by the managed description marker containing namespace and
   `externalId`; a request idempotency key is supplementary, not identity.
3. Classify every record as `CREATE`, `UPDATE`, `UNCHANGED` or `CONFLICT`.
4. If any stable marker is ambiguous, a title collides without a marker, or an
   existing issue is assigned/protected, stop the complete plan.
5. Create only missing records in the existing `kube-ops` project.
6. Resolve parents and blockers only from the canonical stable IDs; never
   invent relations or projects.
7. Keep epics in `backlog` and initial issues in `todo`; never assign, start,
   complete or delegate anything during import.

## Idempotence strategy

- The logical identity is `(project.slug, externalIdNamespace, externalId)`.
- The API request idempotency key is `(externalIdNamespace, externalId)`.
- `externalId` values are stable across title or description edits.
- `seedVersion` is metadata, not a new identity namespace.
- Paperclip has no native issue `externalId`; the adapter owns a reserved
  marker in the managed description and preserves the canonical seed as the
  semantic source of truth.
- Existing matching records are classified as `UNCHANGED` or `UPDATE`, while
  protected or ambiguous records are `CONFLICT`.
- A same-ID/different-content collision is a hard stop requiring human review.
- Re-running a successful import therefore creates zero duplicate records.

## Supported mapping

| Canonical field | Paperclip representation |
| --- | --- |
| `externalId`, `type` | managed description marker |
| `title`, `description` | native issue fields |
| `parentExternalId` | native `parentId` after resolution |
| `priority`, `status` | native fields; canonical `P1`/`P2` map to `high`/`medium` |
| `blockedByExternalIds` | native `blockedByIssueIds` after resolution |
| `source`, acceptance criteria, non-goals, human boundary | managed description metadata |
| `labels` | native `labelIds` only when already resolvable; never create labels implicitly |

Paperclip has no native issue type, durable external ID, or structured
acceptance/evidence/R2 fields. Those semantics remain in Git and in the
managed description marker; they are never silently discarded.

## Explicit non-goals

- No live backlog import in this R1 change.
- No company import in this R1 change.
- No challenge approval or board-token creation.
- No credentials, secrets, Kubernetes mutation or product-intent inference.
