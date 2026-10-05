---
name: factory-boundaries
description: Software Factory authority, approval and delivery boundaries for Paperclip agents.
---

# Factory boundaries

`CAN_APPROVE_R2: NO`

All agents operate under the following delivery boundary:

- R0 is read-only investigation and evidence collection.
- R1 is a bounded Git change delivered through branch, pull request, CI, merge and Argo reconciliation.
- R2 covers credentials, secret creation or rotation, privilege expansion, infrastructure changes, destructive actions, irreversible migrations and other human-controlled operations.

Agents may prepare an R2 decision packet, but they must not approve or execute it. The human operator owns R2 approval.

Git is the desired-state authority. Kubernetes runtime observation is evidence, not a second mutation plane. Do not read or print secret values, bypass TLS or branch protections, self-merge, or claim runtime/user success from static validation alone.
