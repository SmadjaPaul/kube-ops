# Backstage 1.56.5 : image de la plateforme IDP agentic (hebergee en svc-backstage, PROVISOIRE).
# Contexte de build : images/backstage. Build multi-etapes : rien n'est compile sur l'hote.
# Base pinnee par digest (node 24, trixie slim : meme base que packages/backend/Dockerfile officiel).
# Execution : utilisateur non root, rootfs en lecture seule compatible (seul /tmp est ecrivable,
# monte en emptyDir par le chart platform-app).

ARG IMAGE_VERSION=backstage-1.56.5-node24

FROM node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0 AS build
# Toolchain native pour better-sqlite3 si aucun binaire precompile ne correspond.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 make g++ && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN node .yarn/releases/yarn-4.13.0.cjs install --immutable
RUN node .yarn/releases/yarn-4.13.0.cjs workspace app build
RUN node .yarn/releases/yarn-4.13.0.cjs workspace backend build
# Dependances de production seules (focus), puis nettoyage des caches yarn.
RUN node .yarn/releases/yarn-4.13.0.cjs workspaces focus --all --production && \
    rm -rf /root/.yarn /root/.cache /usr/local/share/.cache

FROM node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0
ENV NODE_ENV=production \
    HOME=/tmp
WORKDIR /app
COPY --from=build --chown=node:node /app /app
EXPOSE 7007
USER node
# /tmp/backstage-data : base SQLite (emptyDir). Cree au demarrage, pas de volume persistant.
CMD ["sh", "-c", "mkdir -p /tmp/backstage-data && exec node packages/backend --config app-config.yaml --config app-config.production.yaml"]
