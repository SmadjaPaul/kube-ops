---
title: Personal data platform architecture and roadmap
description: Research, V1 guardrails, and staged path toward portable user-owned data without delaying the first usable homelab.
sidebar_position: 2
---

# Personal data platform architecture and roadmap

## Status

This document records the architectural direction for personal data ownership, portability, deletion, disaster recovery, and eventual inheritance.

The target architecture is intentionally staged. The V1 cluster must become usable before introducing a general-purpose personal data control plane.

The guiding rule is simple: make early decisions that are expensive to reverse after user data exists, and defer abstractions that can be introduced safely after real usage demonstrates a need.

## Product goals

The platform should eventually let a person:

- sign in once through the homelab identity provider;
- understand which data belongs to them and which data belongs to a shared household space;
- export their meaningful data in portable formats;
- leave the platform without depending on Kubernetes backups or application internals;
- request deletion without deleted data silently returning after disaster recovery;
- share selected data without duplicating the canonical data unnecessarily;
- define a controlled transfer policy for selected data if they die or become unable to access the platform;
- allow agents to consume narrowly scoped personal context without giving them unrestricted storage or application credentials.

The system should preserve the existing operating principles: upstream components, standard interfaces, GitOps, minimal custom control-plane code, and small failure domains.

## V1 decision

Applications remain the source of truth for their own user data during V1.

Examples include Immich for photos, Paperless-ngx for managed documents, Open WebUI for conversations, Actual for accounting data, and Home Assistant or Mealie for household data.

V1 does not add a universal asset catalogue, JuiceFS, SeaweedFS, Solid Pods, OpenFGA, a consent engine, a per-user Plakar repository, or a custom Kubernetes operator.

The V1 foundation consists of five contracts:

1. Authentik provides a stable OIDC subject identifier that is not derived from an email address.
2. Data is classified as Personal, Shared, Derived, or System before an application becomes a durable source of user data.
3. Every stateful end-user application has a documented export, deletion, ownership, and restore path.
4. Disaster recovery is validated by successful application-level restore, not only by a completed backup object.
5. Email addresses and usernames are mutable profile attributes, not durable cross-application identity keys.

These contracts preserve a migration path toward the richer personal data platform without delaying first use.

## Identity contract

Authentik is the identity authority.

OIDC providers should use Authentik's persistent hashed user identifier as the subject. Applications should bind an external account to the OIDC subject where supported.

Email-based account merging is not a durable identity strategy. Email addresses can change, be reassigned, or be reported as unverified by an identity provider.

SCIM is preferred when an application supports it cleanly because it can align provisioning and deprovisioning with the same persistent identifier used for SSO. SCIM is not required for V1 if enabling it adds application-specific bootstrap secrets or operational dependencies that delay first-green deployment.

References:

- [Authentik SCIM provider and OIDC identifier alignment](https://docs.goauthentik.io/add-secure-apps/providers/scim/)
- [Open WebUI OAuth configuration](https://docs.openwebui.com/reference/env-configuration/)
- [Open WebUI hardening guidance](https://docs.openwebui.com/getting-started/advanced-topics/hardening/)

## Data classification

Every durable user-facing dataset should fit one of four classes.

| Class | Meaning | Examples | Lifecycle |
| --- | --- | --- | --- |
| Personal | Primarily belongs to one person | private photos, private documents, location history, personal chats | exportable and erasable with that subject |
| Shared | Belongs to a household or shared space rather than one creator | family recipes, shared albums, household automation | survives departure of an individual member |
| Derived | Rebuildable from another durable source | thumbnails, embeddings, search indexes, caches | normally excluded from long-term backup |
| System | Required to operate or audit the platform | deployment state, infrastructure metadata, bounded security logs | governed by system retention rather than user ownership |

This classification is initially architectural documentation, not a new database or policy engine.

## Application admission contract

Before adding a stateful end-user application, its owner should be able to answer the following questions.

| Question | Required outcome |
| --- | --- |
| How is the user authenticated? | Prefer OIDC through Authentik |
| What durable identifier links the account to Authentik? | Prefer OIDC subject or aligned SCIM externalId |
| What data does the application own? | Explicit list of Personal, Shared, Derived, and System state |
| Can one user's meaningful data be exported? | Document API, native export, CLI, or bounded fallback procedure |
| Can one user's meaningful data be deleted? | Document API, native workflow, or bounded fallback procedure |
| What happens to shared data when a user leaves? | Shared ownership must survive individual offboarding |
| What is the application restore unit? | Namespace/PVC, CNPG database, object data, or rebuildable state |
| Can the application be replaced without losing the only usable copy of important data? | Required for durable personal data |

An application that cannot provide export or deletion semantics may still be used for ephemeral or Derived state, but should not silently become the only repository of irreplaceable personal data.

## V1 storage model

V1 keeps storage simple.

Application files continue to use the existing Longhorn storage classes. PostgreSQL applications continue to use CloudNativePG. Application-specific state remains application-owned.

Symlinks are not used as a cross-application data-sharing mechanism. They do not create a security boundary, do not express ownership, and are fragile across container mounts.

Duplication is acceptable when an application requires a working copy and the canonical source is clear. Avoiding every duplicate is less important than maintaining explicit ownership and safe deletion semantics.

A shared canonical object layer is deferred until more than one important application demonstrably needs the same large corpus of files.

## V1 backup and disaster recovery model

The infrastructure disaster-recovery path remains intentionally separate from user data portability.

- ordinary Kubernetes filesystem state uses Velero with Kopia to Hetzner Object Storage;
- PostgreSQL uses CloudNativePG with Barman Cloud and continuous WAL archiving to Hetzner Object Storage;
- Git and Argo CD remain the desired-state authority;
- Derived caches and indexes should be excluded when they are safely rebuildable.

A completed backup is not sufficient evidence. Before real user data is onboarded, at least one representative application restore must prove that restored data is usable by the application.

User export is not a Velero restore and is not a PostgreSQL dump. A future portability export must contain useful end-user formats.

## Exit, deletion, and inheritance

Three lifecycle operations are intentionally treated as separate product features.

### Exit

An exit workflow produces a portable export for a subject. It should prefer ordinary formats such as original files, JSON or JSONL, CSV, VCF, ICS, and GeoJSON rather than infrastructure-specific database or volume formats.

The first implementation may be operator-driven. Automation should follow only after the real export workflow is understood.

### Deletion

Account deprovisioning and data erasure are separate operations.

The safe ordering is to disable access, optionally create a final export, erase application-owned Personal data, remove memberships, verify deletion, record a deletion tombstone, and only then delete the identity record when appropriate.

A deletion ledger becomes necessary before deletion is promised to multiple real users. During disaster recovery it prevents an older backup from resurrecting data that had already been erased.

The CNIL explicitly notes that backup handling must either erase the data from backups or ensure that erased data is not restored into active systems.

Reference: [CNIL guidance on preparing for data-subject rights](https://www.cnil.fr/fr/preparer-lexercice-des-droits-des-personnes)

### Inheritance and emergency transfer

Inheritance is valuable but not a V1 automation requirement.

The early requirement is only to preserve the concept of a designated contact and an operator-readable directive describing which classes of data should be transferred or deleted.

A later implementation should create a new scoped export for the beneficiary rather than reveal infrastructure backup credentials or a full historical backup repository.

## Roadmap

### Phase 0: before first real user

Required:

- stable Authentik OIDC subject;
- no email-based account merge where the application can bind by subject;
- Personal, Shared, Derived, and System classification documented;
- application admission contract adopted;
- current backup targets and agent instructions aligned with the real V1 architecture;
- representative end-to-end restore proven.

Explicitly deferred:

- OpenFGA;
- universal personal data API;
- JuiceFS or SeaweedFS;
- canonical asset catalogue;
- per-space encryption keys;
- consent and purpose engine;
- automated inheritance;
- full GDPR workflow platform.

### Phase 1: dogfood with the operator as the first user

Use the actual applications with real but bounded data.

The purpose is to discover actual cross-application needs rather than predict them. Useful observations include sharing friction, export quality, duplicated files, account mapping issues, restore time, and requests for cross-application search.

No general data platform should be added solely because it may be useful later.

### Phase 2: portability

Build the first high-value cross-application feature: export all meaningful data for one subject.

The first version may be an operator-run script or job that invokes each application's native export path and assembles a temporary portable package.

A permanent duplicate personal vault is not required.

### Phase 3: deletion and offboarding

Automate subject deactivation, application-specific erasure, verification, and a deletion ledger.

This phase should exist before onboarding users for whom full erasure is a promised platform capability.

### Phase 4: shared household spaces

Formalize Personal versus household-owned data when multiple real users need sharing.

Existing application sharing and Authentik groups should be preferred until resource-level relationships become too complex.

### Phase 5: personal data products and agent context

Introduce the personal data pipeline when a real cross-application use case exists.

The previously researched direction remains suitable: ingestion with dlt, durable raw or canonical data in object formats such as Parquet, DuckLake metadata, DuckDB/dbt transformations, and narrow data products exposed to agents.

Agents should receive purpose-specific context rather than direct credentials to every source system.

### Phase 6: advanced authorization

Adopt OpenFGA when coarse Authentik groups can no longer represent the real relationships between users, spaces, assets, beneficiaries, and applications.

OpenFGA should remain an authorization decision layer, not the storage owner.

Reference: [OpenFGA modeling guidance](https://openfga.dev/docs/best-practices/modeling-design-principles)

### Phase 7: canonical shared storage, only if justified

Consider JuiceFS, SeaweedFS, or another object-backed POSIX layer only when multiple important applications require the same large corpus and duplication is materially expensive or operationally painful.

A trigger should be measurable, such as multiple consumers of a multi-terabyte photo or document corpus, rather than architectural preference.

References:

- [JuiceFS architecture](https://juicefs.com/docs/community/architecture/)
- [SeaweedFS Kubernetes CSI support](https://github.com/seaweedfs/seaweedfs-operator/blob/master/CSI_SUPPORT.md)

## Technology research summary

| Technology or pattern | Architectural value | V1 decision |
| --- | --- | --- |
| Authentik persistent OIDC subject | stable identity independent of email | adopt immediately |
| Authentik SCIM | aligned provisioning/deprovisioning | adopt per application when trivial |
| OpenFGA | resource-level relationship authorization | defer until groups are insufficient |
| Solid Pods | strong conceptual model for user-controlled application access | research reference only |
| MyData | strong governance model for human control over personal data | research reference only |
| JuiceFS | one object-backed corpus exposed through filesystem interfaces | defer until duplication is real |
| SeaweedFS | combined object and filesystem access | defer until duplication is real |
| Plakar | attractive integrity, browsing, and portable backup model | evaluate later against Velero/Kopia |
| Nextcloud | strong human file sharing and ownership transfer | application option, not universal data plane |
| Fides OSS | useful access/erasure orchestration patterns | do not adopt; upstream repository was archived in 2026 |
| custom Kubernetes operator | no clear user value for this problem | avoid |

References:

- [Solid Project](https://solidproject.org/about)
- [MyData](https://mydata.org/)
- [Plakar documentation](https://docs.plakar.io/)
- [Nextcloud data-subject rights](https://docs.nextcloud.com/server/stable/admin_manual/gdpr/subject_rights.html)

## Feature value versus complexity

| Feature | End-user value | Platform complexity | Direction |
| --- | --- | --- | --- |
| SSO everywhere | very high | low | V1 |
| reliable photo/document/finance applications | very high | low to medium | V1 |
| tested restore | very high | medium | V1 |
| portable user export | very high | medium | first cross-app feature |
| complete user deletion | very high | medium | before broader multi-user onboarding |
| household sharing | very high | medium | add when second real user arrives |
| cross-application search | very high | high | after dogfood |
| personal agent context | very high | high | after data products exist |
| automated inheritance | high | medium to high | later |
| OpenFGA | indirect until relationships become complex | medium | later |
| universal canonical object plane | low before large shared datasets | high | defer |
| per-space cryptographic keys | low direct value at V1 | very high | defer |
| consent/purpose policy engine | low for a small trusted household | very high | avoid until required |
| Solid-native application ecosystem | uncertain with current applications | very high | research only |

## Architectural trigger checklist

The following triggers justify revisiting deferred components:

- add OpenFGA when resource-level sharing can no longer be represented safely with application permissions and Authentik groups;
- add a canonical object plane when two or more important applications need the same large file corpus and copies become materially costly;
- add the personal analytics/data-product stack when the first useful query needs data from multiple applications or external accounts;
- add a Context API when agents need several personal data sources and direct credentials would broaden the blast radius;
- add automated inheritance when more than one real user depends on the platform and the manual directive is no longer adequate;
- evaluate replacing Velero/Kopia with Plakar only after a restore, storage-efficiency, and operational benchmark on the same dataset.

## Non-goals for V1

V1 is not a general privacy-management SaaS, a Solid implementation, a universal filesystem, or a new Kubernetes control plane.

Its purpose is to deliver a usable homelab with identity and disaster-recovery foundations that do not make later personal-data portability unnecessarily expensive.
