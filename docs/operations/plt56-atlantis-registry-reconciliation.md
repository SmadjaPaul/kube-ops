# PLT-56 — Atlantis server registry reconciliation (2026-11-05)

This is an isolated GitOps-only unblock for homelab-infra
[#235](https://github.com/SmadjaPaul/homelab-infra/pull/235),
extracted from the pending kube-ops #949 change so that backup test
admission does not hold the unrelated Atlantis documentation.

## Exact admission delta

- Current `homelab-infra/main` Git blob SHA for
  `.atlantis/plan-only.yaml`: `26e40fd67a913dd903224434b273f61fcb5cdf5a`.
  This was independently verified by fetching the canonical file.
- Add **only** this blob SHA to the already present exact-value allowlist
  in `k8s/poc/atlantis-plan-only/scripts/github-atlantis-guard.sh`.
- Keep the three historical admitted SHAs, repository/fork/base
  restrictions, approved file paths, HEAD binding, credential controls
  and all denial cases unchanged.
- No Terraform root is registered or activated by this change. No
  Terraform plan/apply permission is expanded.

## Delivery requirements

1. Run static / CI contracts and confirm the rendered guard contains
   exactly the original three SHA values plus the one canonical value.
2. Merge this PR normally only when required GitHub checks are green,
   never using a status override.
3. Wait until Argo `infra-atlantis-plan-only` is Synced/Healthy at the
   new digest/revision. Observe that the `atlantis-server-admission`
   ConfigMap contains the canonical hash.
4. Retry the existing `homelab-infra#235` Atlantis hook. Do not
   assume a plan, any state access or an apply is necessary for
   documentation-only changes.
5. Once this isolated PR is merged, reconcile kube-ops #949 against
   main to remove the duplicate one-line hash addition. Keep its
   contract tests under the separate owner-admission process.

No Kubernetes runtime edit, S3 operation, credential change,
`kubectl delete`, or direct ConfigMap patch is authorized by this
document. There is no measured thermal/I/O benefit yet.
