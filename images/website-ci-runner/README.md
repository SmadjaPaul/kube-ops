# website-ci-runner

Image du scale set ARC `website-ci-arc` (depot `SmadjaPaul/website`, PRD-28) :
`ghcr.io/actions/actions-runner` (meme digest que `homelab-infra-ci-runner`) plus
Node 24.22.2 (dans le cache d'outils Actions, donc vu par `actions/setup-node`),
pnpm 10.17.1 et le Chromium de Playwright 1.58.2 avec ses bibliotheques systeme
(`PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers`).

Publication : `image-build.yaml` (push sur main touchant `images/`), vers
`ghcr.io/smadjapaul/website-ci-runner`. Rien de prive dans l'image.

Bascule : remplacer l'image de
`k8s/optional/github-actions-arc-website/runner-application.yaml` par
`ghcr.io/smadjapaul/website-ci-runner@sha256:<digest publie>`.
