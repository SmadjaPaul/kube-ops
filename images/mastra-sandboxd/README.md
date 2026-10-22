# Mastra sandboxd image

This image keeps the upstream Agent Sandbox `sandboxd` daemon and adds only the
tools required by the Factory command contract: Git and Node.js 22 with npm.
It is built for `linux/amd64`, the Talos node architecture.

The base is the verified amd64 manifest for the upstream Agent Sandbox
`sandboxd:latest-main` image at the time of preparation:

`sha256:a4b16981b52a0c639e32bf7b5abfe80d28f8f3ddb743be006b590db960760da5`

Node.js `v22.23.4` is verified with SHA-256
`1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce` before the
build, and the extracted binary is checked against the requested version. The
resulting image is tested after build for Git, Node, npm, non-root workspace
access and the upstream `sandboxd` command surface.

The image is published by `.github/workflows/image-build.yaml`. The resulting
GHCR digest must be recorded in `k8s/applications/platform/mastra-sandbox` before
the sandbox resources are activated. Until then, `latest-main` is not allowed
in desired state.
