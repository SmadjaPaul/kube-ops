# Polyfin v0.61.1 zlib Trixie backport

This is a downstream candidate change for `linux/amd64`. It does not modify
Polyfin application code and it is not a Debian security release.

## Source provenance

- Debian bug [#1153063](https://bugs.debian.org/1153063)
- Debian source version: `1:1.3.dfsg+really1.3.1-1`
- Upstream zlib v1.3.1 commit: `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`
- Fix commit: [`df84af25dc1942490e1d1c899a07619152a46148`](https://github.com/madler/zlib/commit/df84af25dc1942490e1d1c899a07619152a46148)
- Debian patch SHA-256: `301454f2ee2883b95241692936a884ef73e2a4e6ee1640d6afd3b8a1c7854dbf`
- PoC SHA-256: `566a8ad8c07de43df3c7895175b0d6fc886aef70244851af2581e998f4442f48`

The backport changes only `gzwrite.c`: after a failed compression write it
resets `strm.avail_in` and `strm.next_in`. The package is rebuilt from the
Trixie source package and installed with `dpkg`; no shared library is copied
over a package-managed file.

The downstream package version is
`1:1.3.dfsg+really1.3.1-1+polyfin1`. The Dockerfile asserts that exact version
in the amd64 runtime. The build uses only Trixie `deb-src` and the pinned
Trixie base image; it does not use Sid packages.

## Admission rule

The workflow runs the Debian bug PoC before and after the backport under
ASan/UBSan, `make check`, symbol-set comparison, gzip read/write checks, and
dependency inspection. Trivy still scans the final immutable image without
exclusions. A verified backport does not turn a Trivy residual into a PASS:
the CVE remains a reported finding if the scanner does not recognize the
downstream version, and any other HIGH/CRITICAL finding keeps admission
blocked.
