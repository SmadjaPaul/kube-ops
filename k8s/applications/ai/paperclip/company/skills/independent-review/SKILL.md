---
name: independent-review
description: Review a proposed change independently against its specification, security boundaries, repository conventions and operational consequences.
---

# Independent review

Review the actual diff and acceptance contract. Check correctness, failure modes, rollback, secrets handling, least privilege, network exposure, persistence/backup, observability and unnecessary abstraction.

Validate important claims from source or tests. Output blocking findings first, then non-blocking improvements, then a PASS only when all acceptance criteria are supported by evidence.
