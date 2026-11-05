# Main branch protection drift check

The repository owner must keep `main` protected with the three required
checks: `v1-contract`, `docs-required`, and `workflow-integrity`.

Run the read-only check with an authenticated GitHub CLI session:

```sh
python3 scripts/verify-main-protection.py
```

The command fails closed if the checks disappear, strict up-to-date checks are
disabled, administrators are not enforced, force-pushes are enabled, or branch
deletion is allowed. It never changes GitHub settings and never prints token
or secret values.

This is an operator drift check. Restoring a drifted rule remains an explicit
repository-owner action using the complete GitHub branch-protection contract;
the check must not be replaced by a partial PUT or an automatic bypass.
