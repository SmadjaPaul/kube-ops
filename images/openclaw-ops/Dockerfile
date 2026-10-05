# syntax=docker/dockerfile:1

ARG IMAGE_VERSION=2026.9.6

FROM registry.k8s.io/kubectl:v1.36.3 AS kubectl
FROM ghcr.io/openclaw/openclaw:${IMAGE_VERSION}

# kubectl is supplied at build time; the runtime has no package manager or
# network bootstrap path.
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
