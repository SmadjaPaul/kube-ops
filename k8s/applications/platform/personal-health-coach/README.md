# Personal Health Coach (staged)

This is an independent, proposal-only Mastra runtime. It is deliberately not
included in the active platform kustomization until the dedicated GHCR pull
credential and Authentik client secret are provisioned by their authorities.

The synthetic image is pinned by digest and has no public HTTPRoute. It uses no
Factory identity, database, or write-capable connector. The first activation
must add only dedicated ESO values for the GHCR pull secret, Agentgateway key,
SparkyFitness read-only MCP key, Mealie read-only key, and Authentik client
secret. No secret values belong in this repository.
