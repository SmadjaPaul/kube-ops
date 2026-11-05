# RustiCal pilot

This is a bounded private RustiCal pilot. It uses the reviewed RustiCal image,
route, NetworkPolicy, OIDC contract, durable PVC and Velero schedule, with
synthetic data only. No family data belongs here.

PILOT_GO requires:

- ESO Ready for both the Authentik blueprint Secret and runtime Secret;
- two-user OIDC login/logout and group authorization proof;
- synthetic CalDAV/CardDAV create/read/update/delete checks; and
- a simple rollback path through GitOps.

FAMILY_GO additionally requires all of:

- a SQLite database plus WAL-consistent backup and restore proof;
- CPU, RAM and disk-write measurements; and
- revalidation of the restored calendar and contact through CalDAV/CardDAV.
