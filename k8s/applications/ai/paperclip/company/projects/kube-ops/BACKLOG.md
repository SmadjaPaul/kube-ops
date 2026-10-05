# Seed backlog

This file contains portable backlog seeds for the `kube-ops` Paperclip project.
Import it only through Paperclip's supported company/backlog flow; it is not
runtime task state.

## P1 — Ensure scheduled OpenClaw backup includes `openclaw-data`

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
