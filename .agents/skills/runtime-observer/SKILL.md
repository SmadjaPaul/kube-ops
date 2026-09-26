---
name: runtime-observer
description: Observe the live cluster through bounded read-only interfaces for post-merge verification and SRE diagnosis.
---

# Runtime observer

Normal path:

```text
Git -> Argo MCP read-only -> bounded resource/events/log evidence
```

No Secret reads, exec/attach/port-forward, kubectl mutation, Argo sync, Talos mutation or infrastructure mutation.

An Omnigent managed runner may create a Git branch/PR for a fix. Runtime observation never becomes desired-state authority.
