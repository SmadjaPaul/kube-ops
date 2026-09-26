---
name: tool-discovery
description: Select the smallest tool or MCP that can answer the current task.
---

# Tool discovery

Order: local repo/render -> focused skill -> authoritative upstream docs/schema -> focused read-only MCP -> live read-only runtime tool.

Default runtime MCP: Argo CD MCP with `MCP_READ_ONLY=true` and a readonly Argo account.

Use Talos/Grafana/Kubernetes tooling only when their evidence is specifically required. Never expose secret values through an MCP.
