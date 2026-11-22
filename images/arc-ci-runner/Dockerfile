# Runner commun des scale sets ARC (kube-ops, homelab-infra, homelab-iac-pilot,
# website, agent-harness). Image officielle actions-runner (pin par digest) plus
# la boite a outils des depots, preinstallee : un job ne telecharge plus rien
# (l'egress des scale sets refuse la plupart des hotes de telechargement et
# chaque telechargement coutait 20 a 90 s par job).
#
#   - apt : libatomic1 (Node 26+), xz-utils, python3/pip/venv, curl, unzip.
#   - mise : mise.toml + mise.lock de ce dossier (shellcheck, jq, yq, gh, tofu,
#     tflint, pre-commit, gitleaks, zizmor, helm, kustomize, kubeconform,
#     kyverno, pnpm, Node 22/24/26, ruby...), installes en mode --locked dans
#     /usr/local/share/mise/installs. mise lit ce dossier partage a l'execution :
#     `mise install --locked` d'un depot dont le mise.lock est identique est un
#     no-op ; une version differente ne telecharge que l'outil modifie.
#   - liens dans /usr/local/bin pour les jobs sans mise (agent-harness, website).
#   - Node dans /opt/hostedtoolcache : actions/setup-node le trouve sans
#     telechargement (versions 22, 24, 26).
#   - Chromium de Playwright (website) et le CLI claude (agent-harness).
# Rien de prive, aucun secret dans l'image.
# Playwright : version alignee sur website (scripts/visual/playwright-version.txt),
# a mettre a jour avec ce depot, donc volontairement sans commentaire Renovate.
FROM ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807

ARG IMAGE_VERSION=tools1
ARG MISE_VERSION=2026.11.7 # renovate: datasource=github-releases depName=jdx/mise
ARG PLAYWRIGHT_VERSION=1.58.2

LABEL io.github.smadjapaul.arc-ci-runner.manifest="/etc/arc-ci-runner/tools.json"

USER root

ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers \
    MISE_SHARED_INSTALL_DIRS=/usr/local/share/mise/installs \
    MISE_AUTO_UPDATE=false \
    MISE_YES=1

COPY mise.toml mise.lock package.json package-lock.json /opt/ci-build/

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils libatomic1 \
        python3 python3-pip python3-venv; \
    # mise : binaire de la release, somme de controle de la meme release.
    cd /tmp; \
    base="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}"; \
    curl -fsSLO "$base/mise-v${MISE_VERSION}-linux-x64"; \
    curl -fsSLO "$base/SHASUMS256.txt"; \
    grep " \./mise-v${MISE_VERSION}-linux-x64\$" SHASUMS256.txt | sed "s# \./# #" | sha256sum -c -; \
    install -m 0755 "mise-v${MISE_VERSION}-linux-x64" /usr/local/bin/mise; \
    rm -f "mise-v${MISE_VERSION}-linux-x64" SHASUMS256.txt; \
    # Toolchain verrouillee, installee dans le dossier partage.
    cd /opt/ci-build; \
    export MISE_DATA_DIR=/usr/local/share/mise MISE_TRUSTED_CONFIG_PATHS=/opt/ci-build; \
    mise install --locked; \
    for t in shellcheck shfmt jq yq gh gitleaks tofu terraform tflint terraform-docs \
             pre-commit yamllint zizmor helm kustomize kubeconform kyverno pnpm just uv \
             actionlint conftest markdownlint-cli2 rg; do \
        ln -sf "$(mise which "$t")" "/usr/local/bin/$t"; \
    done; \
    # Node : un dossier par version dans le cache d'outils de GitHub Actions.
    for d in /usr/local/share/mise/installs/node/*; do \
        # mise cree aussi des alias (24.22 -> 24.22.3) : on les ignore.
        [ -L "$d" ] && continue; \
        v="$(basename "$d")"; \
        mkdir -p "$AGENT_TOOLSDIRECTORY/node/$v"; \
        ln -s "$d" "$AGENT_TOOLSDIRECTORY/node/$v/x64"; \
        touch "$AGENT_TOOLSDIRECTORY/node/$v/x64.complete"; \
    done; \
    node24="$(find /usr/local/share/mise/installs/node -mindepth 1 -maxdepth 1 -type d -name '24.*')"; \
    ln -sf "$node24/bin/node" /usr/local/bin/node; \
    ln -sf "$node24/bin/npm" /usr/local/bin/npm; \
    ln -sf "$node24/bin/npx" /usr/local/bin/npx; \
    export PATH="$node24/bin:$PATH"; \
    # CLI claude (agent-harness : `claude plugin validate`), versions via package-lock.
    mkdir -p /opt/ci-npm; cp package.json package-lock.json /opt/ci-npm/; \
    npm ci --prefix /opt/ci-npm --no-audit --no-fund; \
    ln -sf /opt/ci-npm/node_modules/.bin/claude /usr/local/bin/claude; \
    # Chromium et ses bibliotheques systeme, version de Playwright du depot website.
    npm install --prefix /opt/playwright-cli --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION}"; \
    /opt/playwright-cli/node_modules/.bin/playwright install chromium --with-deps; \
    # Manifeste des versions embarquees (lu par le workflow de derive et les CI).
    mkdir -p /etc/arc-ci-runner; \
    mise ls --installed --json > /etc/arc-ci-runner/tools.json; \
    chown -R 1001:1001 "$AGENT_TOOLSDIRECTORY" "$PLAYWRIGHT_BROWSERS_PATH"; \
    rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache /tmp/*

# Meme utilisateur non root (uid 1001) que l'image amont et que le securityContext
# des scale sets. Controle de l'image : tous les outils tournent sans reseau et
# `mise install --locked` ne telecharge rien depuis un HOME vierge.
USER runner
RUN set -eux; \
    export HOME="$(mktemp -d)"; \
    cd /opt/ci-build; \
    MISE_OFFLINE=1 MISE_TRUSTED_CONFIG_PATHS=/opt/ci-build mise install --locked; \
    shellcheck --version | grep -q 0.11.0; \
    node --version | grep -q '^v24\.22\.3$'; \
    test -s /etc/arc-ci-runner/tools.json; \
    test -x "$AGENT_TOOLSDIRECTORY/node/22.23.5/x64/bin/node"; \
    pnpm --version | grep -qx 10.17.1; \
    tofu version | head -1; \
    zizmor --version; helm version --short; kustomize version; kubeconform -v; kyverno version; \
    gh --version | head -1; yq --version; jq --version; gitleaks version; tflint --version; \
    pre-commit --version; claude --version; \
    test -x "$(find "$PLAYWRIGHT_BROWSERS_PATH" -name chrome -type f | head -1)"
