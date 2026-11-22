# GitHub Configuration: CI/CD and Repository Maintenance

This page explains how GitHub Actions, Renovate, and Dependabot keep this homelab repository secure, up to date, and straightforward to maintain.

---

## GitHub Actions Workflows (`.github/workflows/`)

### Docker Image Build (`image-build.yaml`)

- **File:** `.github/workflows/image-build.yaml`
- **Purpose:** Builds only Docker images with changed Dockerfiles and pushes them to GHCR.
- **When triggered:** Pushes to `main`, tags matching `*-*`, and pull requests that change files under `images/`.
- **How it works:**
  1. Finds image folders with modified Dockerfiles.
  2. If run on a tag like `image-<version>` and no files changed, it builds that image anyway.
  3. Skips the build job when no images are found.
- **Permissions:**
  - `contents: read` (clone the repository)
  - `packages: write` (upload images)
- **Build context:** Uses `.dockerignore` files within each image directory to keep uploads minimal.
- **Labels:** Each `Dockerfile` defines `org.opencontainers.image.description` to clarify the image contents.

### Documentation Lint (`vale.yaml`)

- **File:** `.github/workflows/vale.yaml`
- **Purpose:** Lints Markdown files in `website/docs` using [Vale](https://vale.sh/).
- **When triggered:** Only when `.md` files change under `website/docs/`.
- **How it works:** The workflow runs Vale only on the Markdown files that changed in the PR.

### Validation & CI (Implied Workflows)

- **What:** While specific workflow YAMLs for all validation steps aren't detailed here, CI jobs automatically lint and validate configurations.
- **Purpose:** Automatically lint and validate configurations (Kubernetes, Helm charts, scripts) on every push or PR.
- **When triggered:**
  - Every push to `main`
  - Every pull request to `main`
- **Jobs can include:**
  - YAML and script linting
   - Kustomize and ArgoCD validation (using `kustomize build` and ArgoCD CLI tools)
   - Helm chart checks (using `helm lint` or `helm template`)
- **Why:**
  - **Automation:** Prevents errors and broken configs from reaching production.
  - **Quality gate:** Fails builds if code doesn’t meet standards.

---

## Renovate (`renovate.json`)

- **File:** `renovate.json`
- **Purpose:** Keep dependencies current across Dockerfiles, Helm charts, Terraform, and other configs.
- **Why use Renovate?**
  - **Broad coverage:** Handles many ecosystem updates in one tool.
  - **Automatic PRs:** Creates update pull requests with minimal manual work.
  - **Groupes par famille de risque :** npm, GitHub Actions, images sans état, charts Helm et providers OpenTofu en lots ; composants critiques (Cilium, CNPG, Authentik, ESO, Argo CD, Longhorn, Velero, kube-prometheus) en PR individuelles ; Factory/Mastra gelé.
  - **Dependency Dashboard :** issue du dépôt, case à cocher pour lancer un run.

---

## Dependabot (alertes de sécurité)

- Le fichier `.github/dependabot.yml` a été supprimé : Renovate couvre seul les mises à jour de version (npm, Terraform, Docker, GitHub Actions, Helm).
- Dependabot ne reste actif que pour les alertes de sécurité, via les réglages du dépôt.

---

## Summary

By combining GitHub Actions (automated CI), Renovate (dependency updates), and Dependabot security alerts, this repo stays:

- High quality
- Secure
- Automated
- Straightforward to maintain

For more details, see the relevant configuration files under `.github/`.
