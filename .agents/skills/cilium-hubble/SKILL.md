---
name: cilium-hubble
description: Check whether Cilium network policy drops traffic for a namespace or between two workloads ("is X blocked?", "why can't app A reach app B?").
---

# Cilium policy drops

1. Read the CiliumNetworkPolicy of the source and destination namespaces in Git. Every application namespace is default-deny ingress and egress: look for the missing egress rule on the source side and the missing ingress rule on the destination side.
2. Compare with the cluster: `bash scripts/kubectl-ro.sh get ciliumnetworkpolicies -n <ns>` and `bash scripts/kubectl-ro.sh get ciliumendpoints -n <ns>` (policy enforcement state per endpoint).
3. Measure drops in Prometheus through `bash scripts/kubectl-ro.sh get --raw` on the monitoring query API: `sum by (reason) (rate(hubble_drop_total[5m]))`. A rise of `POLICY_DENIED` that matches the failure is evidence. These metrics carry no namespace label by default: they show that drops exist, not which pair.
4. Per-flow proof (`hubble observe --namespace <ns> --verdict DROPPED`) needs a Hubble relay port-forward, which no repository wrapper admits. Without it, report the flow verdict as `NOT_PROVEN` and name the missing capability.

A zero drop rate does not prove that a namespace's traffic flows: it needs evidence that covers the investigated pair, such as a successful request from the source workload to the destination in application logs. Without it, report `NOT_PROVEN`.
