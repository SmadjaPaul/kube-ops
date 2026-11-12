# homelab-infra-ci-runner

Image du scale set ARC `homelab-infra-ci-arc` : `ghcr.io/actions/actions-runner`
(digest inchange) plus `libatomic1`, requis par les binaires Node officiels 26+.

Publication : `image-build.yaml` (push sur main touchant `images/`), vers
`ghcr.io/smadjapaul/homelab-infra-ci-runner`.

Bascule : apres publication, remplacer l'image de
`k8s/optional/github-actions-arc-homelab-infra/runner-application.yaml` par
`ghcr.io/smadjapaul/homelab-infra-ci-runner@sha256:<digest publie>`, puis
verifier la synchronisation Argo (voie locale) et un run `static-ci` de
homelab-infra avec Node 26.
