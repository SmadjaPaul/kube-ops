# PLT-56 — Arr policy retirement

This change is deliberately separate from the media workload retirement in
#1172. It removes the three historical Arr/Prowlarr/Decypharr Cilium policies
from the active Kustomize graph and evolves the protected contract to assert
that boundary.

The source YAML files remain in place as historical audit and rollback
evidence. They are not rendered by the active policy root. No Kubernetes
mutation, namespace deletion, PVC deletion, Longhorn deletion, or GitHub
protection change is part of this PR.

Admission remains normal: the protected harness and `.justfile` paths require
the existing owner-controlled workflow-integrity registry admission in a
separate registry-only PR. This PR must not self-authorize that admission.
