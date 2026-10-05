# Seed backlog

This file is the human-readable companion to `backlog-seed.yaml`. The YAML
manifest is canonical; this file is not live Paperclip task state and must be
imported only through Paperclip's supported preview/import flow.

## Seed shape

- Stable identity: `externalId` in the `smadja/kube-ops` namespace.
- Planning structure: 17 named `EPIC` records (`KOPS-E01` through `KOPS-E17`).
- Initial work: 10 `todo` records (`KOPS-I001` through `KOPS-I010`).
- Deferred backlog work: 1 `backlog` record (`LLM-010`).
- Allowed issue types: `EPIC`, `EXECUTE`, `DISCOVER`, `DECIDE`, `HUMAN`.
- Import policy: preview first, fail on collisions, never replace existing
  records, and require human approval.

## Preserved backup follow-up

`KOPS-I001` preserves the existing OpenClaw backup follow-up seed. It is one
item, not a duplicate:

Context: the scheduled OpenClaw backup observed on 2026-10-05 did not contain
volume data for the legacy `openclaw/openclaw-data` PVC. The isolated restore
proof succeeded from the targeted backup
`openclaw-restore-proof-data-20261005`.

Acceptance criteria:

- A normal scheduled OpenClaw backup contains completed volume data for
  `openclaw/openclaw-data`.
- An isolated restore succeeds from that scheduled backup and binds a new PVC.
- The restored filesystem is readable without mutating the legacy PVC.
- No ad-hoc targeted backup is required for the proof.

Non-goals:

- Do not delete, replace, scale, or restore over the legacy PVC.
- Do not expose the restore publicly or inject production credentials.

## Import boundary

No Paperclip company or live backlog was imported while creating this seed.
See `IMPORT-PLAN.md` and `RECONCILIATION-REPORT.md` for the bounded plan and
the metadata-only reconciliation result.

## Deferred LiteLLM migration

`LLM-010` records the remaining Perplexica master-key consumer. It is a
backlog item, not an authorization to create credentials or execute R2.
