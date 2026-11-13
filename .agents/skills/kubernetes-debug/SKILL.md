---
name: kubernetes-debug
description: Diagnose CrashLoopBackOff, ImagePullBackOff, readiness, PVC, Service/EndpointSlice and Gateway backend failures.
---

# Kubernetes debugging

For HTTP failures inspect: HTTPRoute Accepted/ResolvedRefs -> Service selector/port -> EndpointSlice ready endpoints -> Pod readiness -> logs.
For startup compare Kubernetes command/args with the image OCI ENTRYPOINT/CMD before adding shell wrappers.
Read Secret names/references only. Never print Secret data. Fix desired state in Git; a reversible imperative action (restart, scale, rollout) on a reconstructible workload is allowed per AGENTS.md Safety, verified at runtime and reconciled into Git (write identity: PLT-237, read-only until deployed).
