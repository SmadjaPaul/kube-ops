# Application security tiers

This policy separates vulnerability evidence from the admission decision. A
scan is always retained; a risk acceptance never means that a CVE is fixed.
The tier is chosen from data sensitivity, real exposure, reachable attack
paths and workload privileges.

| Tier | Scope | Default admission |
| --- | --- | --- |
| T0 | Critical infrastructure and identity roots | Strict; no residual acceptance without a separate explicit decision |
| T1 | Applications with important or durable data | High; restore, least privilege and security gates remain strict |
| T2 | Family media applications (Polyfin, AIOStreams, Jellyfin, RomM, BookOrbit) | Complete Trivy evidence; controlled, expiring residual acceptance is possible |
| T3 | Disposable synthetic-data pilots | Informational scan; never a production promotion gate |

T2 exceptions require all of the following:

- immutable image provenance and exact digest tracking;
- private, bounded exposure with no unapproved external route;
- preserved Cilium/NetworkPolicy isolation and isolated credentials;
- non-root execution, no service-account token, dropped capabilities and
  read-only root filesystem where the workload supports them;
- explicit per-CVE rationale and expiry;
- no known actively exploited vulnerability with an reachable grave impact;
- immediate re-evaluation on digest, perimeter, privilege or fixed-version
  changes.

The complete Trivy report remains an artifact even when the T2 verdict passes.
The Polyfin implementation is intentionally narrow: the legacy policy remains
strict by default, while `.github/polyfin/private-pilot-admission-v060.json`
uses the `risk-accepted` mode for the private 0.60 pilot only. T0 and T1
policies must not opt into that mode.

The risk acceptance does not authorize IPTV/XMLTV, public ingress, privileged
containers, shared production credentials, or a migration against an active
database.
