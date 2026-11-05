# User-facing apps — GitOps delivery map (5 November 2026)

> This is a **dated handoff**, not a runtime dashboard. Always verify the
> latest `main`, Linear evidence and Argo applied revision before acting.
> Machine-readable snapshot: `user-apps-rollout-2026-11-05.json`.

## Product intent and delivery principles

One family identity via Authentik; minimal duplicate UIs/services; GitOps
source-of-truth at `SmadjaPaul/kube-ops`; single-node 64 GiB host with
costly/limited disk writes; media direct-to-CDN where possible. Never
claim USER_READY from CI/HTTP 200 alone: require actual authenticated
user actions. Do not expose manifest URLs, cookies, keys, signed CDN
URLs or identity claims in chat, Git, Linear or logs.

Use existing `just kube-access-check` / Doppler auto-bootstrap, then
`just status-app apps-media` and `just status-app apps-games`;
unavailable access is a BLOCKED gate, not permission to skip it.

## Current execution matrix

| Goal | Evidence | Next action |
|---|---|---|
| Polyfin music | [PLT-133](https://linear.app/boule/issue/PLT-133): Brave 3 songs + images + favorite PASS. | Safari USER proof separately; do not reopen Cilium. |
| AIOStreams video in Polyfin | [PLT-134](https://linear.app/boule/issue/PLT-134): [#932](https://github.com/SmadjaPaul/kube-ops/pull/932) native pilot script merged; **not installed**. | Approved secret-file manifest, test offline, guarded install, family video/CDN+FR subtitles. |
| Local Live TV | [PLT-135](https://linear.app/boule/issue/PLT-135): Polyfin supports M3U/Xtream/HDHomeRun. | Wait for authorized LAN source; only then EPG/channel playback. |
| RomM family login | [PLT-136](https://linear.app/boule/issue/PLT-136): app/DB healthy; viewer callback 403; exact 5.2.0 role root cause identified. [#933](https://github.com/SmadjaPaul/kube-ops/pull/933) proposed. | **Protected merge path**; after merge, browser family viewer and negative guest. Restore independently. |
| RustiCal | [PLT-137](https://linear.app/boule/issue/PLT-137): OIDC and DAV CRUD PASS; active pilot uses emptyDir. | Small, isolated SQLite/WAL PVC+backup proof, then Apple/Android DAV clients. |
| SparkyFitness | [PLT-138](https://linear.app/boule/issue/PLT-138): [#846](https://github.com/SmadjaPaul/kube-ops/pull/846) staged Helm chart; local RLS synthetic PASS. | Missing dedicated OIDC/SQL/S3 secrets and restore; **no active Argo import**. MVP workout+nutrition first. |
| BookOrbit | [PLT-122](https://linear.app/boule/issue/PLT-122): v3.6 [#875](https://github.com/SmadjaPaul/kube-ops/pull/875) DRAFT, synthetic-only S3. | Identity, least-privilege S3 and restores, legal book fixture. Avoid premature promotion. |
| La Suite Docs/Drive | [PLT-139](https://linear.app/boule/issue/PLT-139): [#847](https://github.com/SmadjaPaul/kube-ops/pull/847) scaffold only. | CNPG/Valkey/S3/WOPI/backup and missing Doppler references; not deployable yet. |
| Personal family agents | [PLT-35](https://linear.app/boule/issue/PLT-35), [PLT-36](https://linear.app/boule/issue/PLT-36), [PRD-14](https://linear.app/boule/issue/PRD-14). | Memory/thread isolation and permission denial before a multi-user portal. |

## Parallel workstreams without collisions

**Track A: Existing user functionality**, can progress first:
- Polyfin video AIOStreams using `scripts/polyfin-aiostreams-pilot.mjs`,
  `scripts/polyfin-aiostreams-pilot.test.mjs` and
  `docs/operations/polyfin-aiostreams-video-pilot.md`.
- RomM viewer fix in #933: precise scalar change only. No Authentik
  wildcard role, no change to users or admin group. Runtime proof required.
- Safari live music smoke after Brave PASS; no new infra unless regression.

**Track B: Data-bearing pilots**, may prepare docs/PRs in parallel but
must be deployed one at a time on the constrained host:
- RustiCal durable SQLite/WAL with isolated restore.
- SparkyFitness offline Helm/image and secrets-presence checks, isolated
  database/backup/OIDC test; no dynamic signups.
- BookOrbit synthetic-only QA and IAM positive/negative tests.

**Track C: Larger optional projects**:
- La Suite dependency closure. Do not import dormant root.
- Live TV once an actual authorized source exists.
- Personal agents/portal after principal-level isolation.

## GitOps workflow and acceptance gates

1. Fetch current `main` in `kube-ops` and read each Linear ticket and
   active/dormant Kustomization before patching. Be wary of multiple
   agents changing the same root. Keep PRs atomic per app.
2. Qualify `kustomize build` (and Helm where relevant), no secrets or
   dangerous rollout; validate policy selectors and persistent storage.
3. Preserve GitHub required checks (`v1-contract`,
   `workflow-integrity`, `docs-required`), use normal merge. For
   protected/security-sensitive changes, honor required approval and do
   not bypass a tool or branch protection refusal.
4. Argo `Synced/Healthy` on exact merge SHA; ESO/CNP/DB ready; then
   *real* Browser/Apple/Android tests with a non-admin family principal.
5. Two users must not access each other's data; test denied access,
   backup/restore after restart, and rollback before promoting any
   stateful app.
6. Measure CPU/RAM/disk writes when possible; otherwise record
   NOT_MEASURED, never guess. No auto-cold TorBox downloads in CI.
7. Publish only status/digest/latency/error category to relevant Linear
   ticket. Never print session tokens, URLs with queries or secret values.

## Explicit out-of-scope

Do not modify `tv.smadja.dev`, remove AIOStreams, uninstall Nebula,
re-add Audiobookshelf without a product decision, restore the abandoned
Arr downloader chain without authority, delete PVCs, force Argo prune,
run SQL resets, weaken Authentik or disable K8s policies globally.

Keep `apps-media` and `apps-games` production states independent.
