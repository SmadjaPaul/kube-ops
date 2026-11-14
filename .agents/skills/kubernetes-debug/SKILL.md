---
name: kubernetes-debug
description: Diagnose CrashLoopBackOff, ImagePullBackOff, readiness, PVC, Service/EndpointSlice and Gateway backend failures.
---

# Kubernetes debugging

For HTTP failures inspect: HTTPRoute Accepted/ResolvedRefs -> Service selector/port -> EndpointSlice ready endpoints -> Pod readiness -> logs.
For startup compare Kubernetes command/args with the image OCI ENTRYPOINT/CMD before adding shell wrappers.
Read Secret names and references only. Fix desired state in Git. A reversible action (restart, scale, rollout) on a reconstructible workload goes through `scripts/kubectl-rw.sh` per AGENTS.md Safety.
