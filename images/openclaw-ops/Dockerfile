# syntax=docker/dockerfile:1

ARG IMAGE_VERSION=2026.10.5

FROM registry.k8s.io/kubectl:v1.37.1 AS kubectl
FROM ghcr.io/openclaw/openclaw:${IMAGE_VERSION}

# kubectl is supplied at build time; the runtime has no package manager or
# network bootstrap path.
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
