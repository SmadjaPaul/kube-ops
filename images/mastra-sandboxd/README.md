# Mastra sandboxd image

This image keeps the upstream Agent Sandbox `sandboxd` daemon and adds only the
tools required by the Factory command contract: Git and Node.js 22 with npm.
It is built for `linux/amd64`, the Talos node architecture.

The base is the verified amd64 manifest for the upstream Agent Sandbox
`sandboxd:latest-main` image at the time of preparation:

`sha256:a4b16981b52a0c639e32bf7b5abfe80d28f8f3ddb743be006b590db960760da5`

Node.js `v22.23.3` is verified with SHA-256
`df450af89261115ef9f3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de` before the
build. The resulting image is tested after build for Git, Node, npm, non-root
workspace access and the upstream `sandboxd` command surface.

The image is published by `.github/workflows/image-build.yaml`. The resulting
GHCR digest must be recorded in `k8s/applications/platform/mastra-sandbox` before
the sandbox resources are activated. Until then, `latest-main` is not allowed
in desired state.
