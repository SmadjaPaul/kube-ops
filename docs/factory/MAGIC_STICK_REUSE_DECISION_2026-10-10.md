# AIppliance Magic Stick reference audit — Paperclip / OpenCode

**Status:** research and non-live contract test only. No deployment or runtime changes.
**Date:** 2026-10-10
**Primary reference:** https://github.com/QualityMinds/AIppliance-Magic-Stick

## Decision

Do not vendor Magic Stick manifests, copy its operator, or introduce a second model-catalog controller. Its own code/manifests are under BSL 1.1, not MIT. Its additional production-use grant restricts SaaS and managed-service uses in which Magic Stick is a material component. Review LICENSE and LICENSING.md before copying any source; upstream third-party components retain their own licenses.

The reusable architecture principle is a single model catalog consumed by Paperclip/OpenCode and other applications. Our Git-owned LiteLLM config already defines the model list. The Paperclip OPENCODE_CONFIG_CONTENT is a consumer projection, not a second catalog database.

## Selective reuse

| Magic Stick capability | Existing source of truth | Decision |
|---|---|---|
| Paperclip operator, CNPG | kube-ops Paperclip | Keep existing |
| Flux, Envoy, Keycloak, secrets | Argo CD, Cilium, Authentik, ESO | Do not import |
| LiteLLM model catalog | kube-ops LiteLLM | Verify aliases; no new controller |
| OpenCode runtime | Paperclip upstream plugin / paperclip PR #11 | Retain upstream image by digest |
| Agent Sandbox | kube-ops PR #397/#400 | Qualify v1beta1 separately, without activation here |
| Sandbox cleanup/workspace | Paperclip upstream implementation | Test behavior; do not copy boot-time source patches |
| Appliance UI, GPUs, KubeOpenCode | Outside coding agent V1 | Defer |

## New CI contract

Run: bash tests/harness/paperclip-litellm-model-contract-test.sh

The test proves that the OpenCode LiteLLM endpoint matches the declared Kubernetes Service, all advertised aliases are present in the Git-owned LiteLLM model list, default/small models are advertised, and the API key is an environment reference provided by ESO.

This static test makes no model requests and does not read Secret values. It is deliberately not proof that a Kubernetes Sandbox, plugin loader, GitHub run, or runtime credentials work. E2E and security gates remain separate.

## References

- https://github.com/QualityMinds/AIppliance-Magic-Stick/blob/main/docs/reference/paperclip-agents.md
- https://github.com/QualityMinds/AIppliance-Magic-Stick/blob/main/magic-cluster/apps/ai/model-catalog/controller.py
- https://github.com/QualityMinds/AIppliance-Magic-Stick/blob/main/LICENSE
- https://github.com/QualityMinds/AIppliance-Magic-Stick/blob/main/LICENSING.md
