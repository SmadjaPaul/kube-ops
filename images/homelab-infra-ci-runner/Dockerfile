# Runner ARC de homelab-infra (scale set homelab-infra-ci-arc) : image officielle
# actions-runner (pin par digest) plus libatomic1. Les binaires Node officiels
# 26+ liaient libatomic.so.1, absente de l'image de base : `mise install node@26`
# sort en exit 127 et le job `check` de homelab-infra devient rouge (PLT-207,
# PR homelab-infra#355). Aucun autre changement par rapport a l'image amont.
FROM ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends libatomic1 \
    && rm -rf /var/lib/apt/lists/* \
    && ldconfig -p | grep -q 'libatomic\.so\.1'

# Meme utilisateur non root (uid 1001) que l'image amont et que le securityContext
# du scale set.
USER runner
