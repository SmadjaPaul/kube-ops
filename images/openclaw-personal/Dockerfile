# syntax=docker/dockerfile:1

# The upstream runtime is already qualified in the personal-AI runbook. This
# derivative only adds the exact official Hindsight plugin package; it does
# not add tools, credentials, or Factory access.
ARG IMAGE_VERSION=2026.11.2-hindsight-1.2.0
FROM ghcr.io/openclaw/openclaw:2026.11.2@sha256:c764f17ed94b725599043f0548ece6297f1fe4409e6dd1133b1d2fb1f8d2b599

USER root
WORKDIR /opt/openclaw-personal-plugin
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
    && mkdir -p /opt/openclaw-plugins \
    && ln -s /opt/openclaw-personal-plugin/node_modules/@vectorize-io/hindsight-openclaw /opt/openclaw-plugins/hindsight-openclaw \
    && npm cache clean --force

USER node
