---
name: oidc-integration
description: Integrate or debug Authentik OIDC without confusing identity failures with DNS/TLS/backend failures.
---

# OIDC integration

Before OAuth debugging prove backend readiness, internal DNS, valid TLS and OIDC discovery from the application pod.
Then compare client ID, callback URI, grant type, scopes and required claims with current upstream documentation.
Keep local login until the first admin OIDC login is proven when the app supports that recovery path.
Secrets come from Doppler -> ESO; never read values.
