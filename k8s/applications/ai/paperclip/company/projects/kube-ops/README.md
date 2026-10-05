# `kube-ops` backlog seed

This directory is the Git-native backlog seed for the `kube-ops` Paperclip
project. It is part of the portable company package under `company/`; it is
not live Paperclip state and it must never be imported automatically by
Argo CD or Kubernetes.

## Contents

- `backlog-seed.yaml` is the canonical declarative payload.
- `scripts/paperclip/import-backlog-seed.mjs` is the dry-run-first adapter for
  Paperclip's supported issue API; `paperclipai company import` does not parse
  this custom seed schema.
- `BACKLOG.md` is the human-readable index and preserves the existing
  OpenClaw backup follow-up seed.
- `IMPORT-PLAN.md` describes the preview, collision and human-approval gates.
- `RECONCILIATION-REPORT.md` records what was checked without reading or
  changing the live Paperclip backlog.

The seed contains 17 planning epics and 10 initial `todo` issues. The issue
types are intentionally explicit: `EPIC`, `EXECUTE`, `DISCOVER`, `DECIDE` and
`HUMAN`. The epics are planning containers, not product commitments inferred
from Kubernetes resources. Product intent remains a human decision.

## Authority and safety

- Git is the source of truth for this seed.
- Paperclip is the runtime work-state store after an explicitly approved
  import; it is not the source of truth for this file.
- Imports must use Paperclip's supported preview/import flow and must fail
  closed on an external-ID collision.
- This R1 change does not approve a challenge, import the company, import the
  backlog, create credentials, or mutate runtime systems.
