# Factory GitHub authentication

The software factory never carries a long-lived GitHub credential into an
agent runtime. Every `git` and `gh` operation inside a Paperclip-managed
checkout is authenticated through a single, short-lived path:

```
Paperclip server
  -> sealed GitHub App credentials (App ID + private key + installation ID)
  -> short-lived installation access token
  -> GH_TOKEN / GITHUB_TOKEN / PAPERCLIP_GIT_TOKEN
  -> the repositories the App was authorized to install on
```

This document records that chain so an operator reading this repo can reason
about the runtime boundary without inspecting secret material.

## What the factory holds

GitHub App credentials live in Paperclip's existing encrypted secret store,
keyed per company and per grant. A grant pins one App installation to one
principal (a dedicated agent, or a personal account delegated by its owner)
and the repositories the owner authorized during installation. The App ID,
private key, and installation identifier are sealed values; this document
never names them and operators must never log or print them.

## What a run does on GitHub

An agent, on its behalf, runs `git` or `gh` through the Paperclip `opencode`
adapter. The adapter stands a wrapper binary in front of the real `git`/`gh`
and asks the Paperclip broker endpoint for an access token before each
operation. The request is authenticated by a run-bound capability token
that lives only for the active heartbeat.

Paperclip then performs the canonical exchange:

1. Sign an RS256 JWT with the App's private key. Header `alg=RS256`,
   `typ=JWT`; payload `iss=<App ID>`, `iat=now-60s`, `exp=now+540s`
   (so the token is fresh and never re-used past ten minutes).
2. `POST https://api.github.com/app/installations/<installation ID>/access_tokens`
   with that JWT as a bearer and the pinned
   `x-github-api-version: 2022-11-28` header. The response carries a
   single short-lived installation access token plus its expiry.
3. Return the token to the strategy as the value for `GH_TOKEN`,
   `GITHUB_TOKEN`, and `PAPERCLIP_GIT_TOKEN`.

The token grants access to exactly the repositories the App installation
was authorized for at GitHub side. There is no wildcard, no per-call scope
widening, and no reuse across runs.

## Why a wrapper, not just an env var

`GH_TOKEN` is set on a stripped environment that the wrapper constructs.
The wrapper:

- scrubs any inherited `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`,
  `GITHUB_ENTERPRISE_TOKEN`, `PAPERCLIP_GIT_TOKEN`, `GIT_AUTHOR_*`,
  `GIT_COMMITTER_*`, and `GIT_CONFIG_*` from the parent environment;
- sets `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`,
  `GIT_TERMINAL_PROMPT=0`, and a pinned `GIT_SSH_COMMAND` that disables
  SSH key, agent, and askpass use;
- installs a URL-scoped `credential.https://github.com.helper` that
  re-validates the request host and protocol before answering, so a
  rewritten remote cannot trick `git` into releasing the token to an
  unrelated host;
- re-execs the real `git` or `gh` from `PATH` so steering cannot split
  one operation across two credentials.

The wrapper is the only path that ever holds the installation token; the
real Git and GitHub CLI binaries see the cleaned environment and exit as
soon as the operation ends. On run end the capability token is revoked
and the wrapper exits, so the next operation must request a fresh token.

## Operational properties

- **Short-lived.** Installation tokens are fetched per operation, not
  cached across runs. Each new wrapper invocation re-runs the JWT sign
  and the installation-token exchange.
- **Least privilege.** Token grants are whatever the owner authorized
  when installing the App on the target organization or user account;
  the factory never asks for, and never receives, more than that.
- **Audit trail.** Every credential request is bound to the active run,
  the responsible user, the issue, and the agent. Paperclip records
  these bindings in its existing audit log; failures do not persist
  secret material.
- **No secret in argv or on disk.** The token never appears in a
  command line, a remote URL, or a credential store. It reaches `git`
  through the URL-scoped credential helper, which reads it from
  `PAPERCLIP_GIT_TOKEN`.
- **Single broker.** One server-side endpoint is the seam for future
  credential sources; swapping the resolver keeps every call site
  unchanged.

## What this means for an operator

When the factory opens a pull request against this repository, the
credential that signed the push came from this chain and only this chain.
There is no ambient SSH key, no operator-supplied PAT, and no token cached
in the run directory. The repository is reachable because the App
installation owns it; if the operator revokes the installation on the
GitHub side, the next factory operation against it will fail closed and
the operator will see the failure in the run output.