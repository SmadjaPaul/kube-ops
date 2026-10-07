# Invoice Ninja MCP runtime

Thin packaging of [DSS-AI/invoice-ninja-mcp](https://github.com/DSS-AI/invoice-ninja-mcp)
at the immutable upstream commit `f822b554c52676a7e75953c65e2578d9c9fa89dc`.

The upstream project is MIT licensed, runs non-root, exposes Streamable HTTP and
is intentionally narrower than the raw Invoice Ninja API. This repository does
not fork its application code; the build fetches the exact upstream commit and
packages it with its declared Python dependencies.

Invoice mutation tools remain disabled by the instance configuration in
`k8s/applications/business/invoice-ninja/mcp-config.yaml`.
