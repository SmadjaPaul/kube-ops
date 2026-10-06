# How to Contribute

Contributions are welcome. This repository is the canonical GitOps desired state for the Smadja Kubernetes cluster.

## Philosophy

- **GitOps is law:** permanent cluster changes go through Git and Argo CD.
- **Prefer upstream standards:** avoid local abstractions when an upstream Kubernetes primitive exists.
- **Security by default:** use non-root workloads where upstream supports it, network policies, and externalized secrets.

## Getting Started

1. Read the repository [README](../README.md) and [AGENTS.md](../AGENTS.md).
2. Review the relevant documentation under [website/docs](../website/docs).
3. Open a pull request against `main` with a focused change and its validation evidence.

## Required Checks

Before opening a pull request, run the checks relevant to the files you changed:

- **Repository checks:** `mise exec -- just check`.
- **Kubernetes manifests:** render the modified Kustomize tree and verify schemas.
- **Website/docs:** from `website/`, run `npm install`, `npm run typecheck`, and the configured lint checks.
- **Docker images:** validate or build only the image definitions you changed.

Do not commit credentials or generated kubeconfigs. Runtime secrets are delivered through the repository's existing secret-management flow.
