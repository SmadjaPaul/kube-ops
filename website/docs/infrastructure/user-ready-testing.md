---
title: User-ready validation
---

# User-ready validation

The V1 acceptance model has four independent levels. A green Kubernetes control plane is necessary but is not sufficient evidence that a human can use the platform.

## L0: static and render

Pull requests keep the existing V1 repository contract and render checks. The E2E package is also listed by Playwright in CI so syntax and test discovery failures are caught without requiring live credentials.

## L1: cluster convergence

Runtime acceptance requires Argo applications to be synced and healthy, required pods ready, no Pending/CrashLoopBackOff/ImagePullBackOff pods, required ExternalSecrets ready, healthy CloudNativePG clusters, and an Available Velero BackupStorageLocation.

L1 must run from a host with cluster access. It must not mutate workloads to make checks pass.

## L2: synthetic protocol checks

Prometheus Blackbox Exporter probes the four V1 user surfaces every five minutes:

- Authentik
- Argo CD
- Open WebUI
- Home Assistant

OIDC discovery endpoints are checked separately with an exact HTTP 200 expectation. UI probes accept the documented redirect class as well as HTTP 200 because a redirect to authentication is a valid protocol result.

## L3: real browser checks

Playwright runs from outside the Kubernetes failure domain. The canonical target runner is the N100 host. Each critical test uses a fresh browser context and a dedicated non-admin Authentik identity named `e2e-user`.

The browser suite covers Authentik login, Argo CD SSO plus readonly authorization, Open WebUI authentication and main UI rendering, and Home Assistant login/onboarding/dashboard readiness. It does not call a paid LLM provider.

Credential values are never stored in Git or Playwright storage state. Credential-bearing Playwright traces and videos are disabled; JUnit/JSON results and failure screenshots are retained for short-lived diagnostics.

## V1_USER_READY

`V1_USER_READY=PASS` requires all of the following from real runtime executions:

- `PLATFORM_RUNTIME=PASS`
- `DNS_TLS_GATEWAY=PASS`
- `AUTHENTIK_E2E=PASS`
- `ARGO_SSO_E2E=PASS`
- `OPENWEBUI_E2E=PASS`
- `HOME_ASSISTANT_E2E=PASS`

Optional applications do not participate in this gate.
