# Runner ARC du depot website (scale set website-ci-arc, PRD-28) : image officielle
# actions-runner (pin par digest, identique a homelab-infra-ci-runner) plus Node,
# pnpm et le Chromium de Playwright. Ces trois elements ne peuvent pas etre
# installes dans le job : `playwright install --with-deps` exige apt en root, et
# l'egress du scale set refuse nodejs.org et cdn.playwright.dev.
# Versions alignees sur le depot website : .node-version, packageManager,
# scripts/visual/playwright-version.txt. Les mettre a jour ensemble.
FROM ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807

ARG IMAGE_VERSION=node24.22.2-pnpm10.17.1-pw1.58.2
ARG NODE_VERSION=24.22.2
# https://nodejs.org/dist/v24.22.2/SHASUMS256.txt
ARG NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
ARG PNPM_VERSION=10.17.1
ARG PLAYWRIGHT_VERSION=1.58.2

USER root

# Node est installe a l'emplacement du cache d'outils de GitHub Actions : le
# `actions/setup-node` du workflow le trouve sans rien telecharger.
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils libatomic1; \
    node_dir="$AGENT_TOOLSDIRECTORY/node/$NODE_VERSION/x64"; \
    mkdir -p "$node_dir"; \
    curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C "$node_dir" --strip-components=1; \
    rm /tmp/node.tar.xz; \
    touch "$AGENT_TOOLSDIRECTORY/node/$NODE_VERSION/x64.complete"; \
    ln -s "$node_dir/bin/node" /usr/local/bin/node; \
    ln -s "$node_dir/bin/npm" /usr/local/bin/npm; \
    ln -s "$node_dir/bin/npx" /usr/local/bin/npx; \
    npm install -g "pnpm@${PNPM_VERSION}"; \
    ln -s "$node_dir/bin/pnpm" /usr/local/bin/pnpm; \
    # Chromium et ses bibliotheques systeme, avec la version de Playwright du depot.
    npm install --prefix /opt/playwright-cli --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION}"; \
    /opt/playwright-cli/node_modules/.bin/playwright install chromium --with-deps; \
    chown -R 1001:1001 "$AGENT_TOOLSDIRECTORY" "$PLAYWRIGHT_BROWSERS_PATH"; \
    rm -rf /var/lib/apt/lists/* /root/.npm /tmp/*; \
    node --version | grep -qx "v${NODE_VERSION}"; \
    pnpm --version | grep -qx "${PNPM_VERSION}"; \
    test -x "$(find "$PLAYWRIGHT_BROWSERS_PATH" -name chrome -type f | head -1)"

# Meme utilisateur non root (uid 1001) que l'image amont et que le securityContext
# du scale set.
USER runner
