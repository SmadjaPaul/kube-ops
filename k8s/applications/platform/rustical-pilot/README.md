# RustiCal pilot

This is the first bounded RustiCal runtime admission. It reuses the reviewed
RustiCal image, route, NetworkPolicy, OIDC contract and synthetic-only test
plan, but replaces the durable PVC with `emptyDir` and excludes the Velero
Schedule. No family data belongs here.

Promotion to the persistent `k8s/optional/rustical` contract requires all of:

- ESO Ready for both the Authentik blueprint Secret and runtime Secret;
- two-user OIDC login/logout and group authorization proof;
- synthetic CalDAV/CardDAV create/read/update/delete checks;
- a SQLite database plus WAL-consistent backup and restore proof;
- CPU, RAM and disk-write measurements; and
- a separate reviewed promotion PR that restores the PVC and backup schedule.
