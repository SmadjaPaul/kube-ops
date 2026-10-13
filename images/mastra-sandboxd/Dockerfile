# Mastra sandbox runtime: upstream sandboxd plus the tools required by the
# Factory command contract. The upstream daemon remains the only runtime
# adapter; this image only adds packages to its Debian runtime.
FROM us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandboxd@sha256:a4b16981b52a0c639e32bf7b5abfe80d28f8f3ddb743be006b590db960760da5

ARG NODE_VERSION=22.23.3
ARG NODE_SHA256=df450af89261115ef9f3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
    && curl --fail --silent --show-error --location \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      --output /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz --strip-components=1 -C /usr/local \
    && rm -f /tmp/node.tar.xz \
    && rm -rf /var/lib/apt/lists/* \
    && git --version \
    && node --version \
    && npm --version

USER 1000

