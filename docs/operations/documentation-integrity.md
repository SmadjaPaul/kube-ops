# Documentation integrity guardrails

This repository has two documentation gates with different evidence scopes.

## Offline P0 gate

`just docs-check` validates every tracked `AGENTS.md` router. It verifies that
referenced repository paths are tracked, routed skills still contain a
`SKILL.md`, and referenced `just`/npm commands still exist. The same command
runs negative fixtures for missing paths, private material, and active retired
platform/IAM instructions. The checker is intentionally conservative: a
historical statement remains a review finding and is not deleted by grep.

## Public-site gate

The Docusaurus site is still the public documentation entry point. For a pull
request, the documentation workflow passes added lines in changed
`website/docs/*.md` and `website/docs/*.mdx` files through the disclosure and
retired-reference checks. It rejects private network addresses, workstation
paths, kubeconfig fallback paths, credential material, and active references to
retired Flux/home-ops or Bitwarden mechanisms. Existing legacy pages are
therefore visible as audit debt instead of being silently rewritten by a broad
scanner.

`website/docusaurus.config.ts` remains authoritative for link behavior:
`onBrokenLinks` and `onBrokenMarkdownLinks` are both `throw`. The workflow
installs the pinned Docusaurus major/minor dependencies from
`website/package.json` and runs the native `npm run build`; this is the proof
of internal link resolution, not the offline guard.

## Current audit findings

- `website/docs/k8s/applications/sabnzbd-implementation.md` had active
  Bitwarden and Flux instructions; it now names Doppler-backed External Secrets
  and Argo CD.
- `docs/agent-harness.md` referenced the removed Paperclip role matrix; it now
  routes agents to the tracked skills and repository authority rules.
- Historical disaster-recovery and migration pages still contain legacy
  examples and are not rewritten by this P0 PR without an authority-backed
  replacement. They remain an explicit PLT-42 follow-up finding.

This gate is STATIC evidence only. It does not establish RECONCILED, RUNTIME,
or USER evidence.
