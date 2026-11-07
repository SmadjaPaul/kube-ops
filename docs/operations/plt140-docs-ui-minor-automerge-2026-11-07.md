# PLT-140 — documentation UI minor AUTO (2026-11-07)

This narrow follow-up to the first actual Renovate automerge extends *minor* updates for five already patch-eligible documentation UI libraries: `@mdx-js/react`, `clsx`, `prism-react-renderer`, `react-icons`, `typed.js`.

Admission is scoped to stable (non-0.x) npm `dependencies` in `website/package.json`, with a 14-day maturity period, Renovate PR automerge, and unchanged strict CI controls. `docs-required` builds and typechecks the documentation site. No majors, production Kubernetes images, Helm charts, databases, storage, network, or Terraform changes become eligible.

This PR changes policy only; it does not bump dependencies or establish that a future canary merged. Validate with `node --test tests/renovate-policy-test.mjs` and the repository's required checks on the final HEAD. Observe a genuine Renovate bot merge when a qualifying update exists. Missing CI, unknown publication age, and missing protection do **not** count as a PASS.

Remaining PLT-140 work: fix `kube-ops#1036` workflow-integrity, then `homelab-infra#247` Atlantis; fix `homelab-infra#159` terraform-docs drift; verify protected automerge for private repositories; inventory OCI/Helm coverage and batch-upgrade stateless services, with separate controls for critical infrastructure. Keep homelab-infra Renovate limits at 12 concurrent PRs and 3 PRs/hour.
