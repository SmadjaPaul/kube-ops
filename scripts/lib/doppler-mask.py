#!/usr/bin/env python3
"""Run CMD and mask environment values in its stdout/stderr (doppler-safe.sh run).

Usage: python3 -I scripts/lib/doppler-mask.py -- CMD [ARGS...]
Every environment value of MIN_LEN+ characters (each line of a multi-line
value too), except a short allowlist of harmless variables, is replaced with
[MASQUÉ]. Over-masking is accepted; the exit code of CMD is returned.
Limit: derived forms (base64, URL-encoded, split across lines) are not masked.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import threading

MIN_LEN = 8
KEEP = {
    "PATH", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM",
    "SHLVL", "_", "TZ", "EDITOR", "PAGER", "DOPPLER_PROJECT", "DOPPLER_CONFIG",
    "DOPPLER_ENVIRONMENT", "COLORTERM", "TERM_PROGRAM", "XPC_SERVICE_NAME",
}


def secret_values() -> list[str]:
    values = set()
    for name, value in os.environ.items():
        if name in KEEP or name.startswith("LC_"):
            continue
        for part in [value, *value.splitlines()]:
            part = part.strip()
            if len(part) >= MIN_LEN:
                values.add(part)
    return sorted(values, key=len, reverse=True)


def pump(src, dst, pattern) -> None:
    for raw in iter(src.readline, b""):
        line = raw.decode("utf-8", "replace")
        if pattern is not None:
            line = pattern.sub("[MASQUÉ]", line)
        dst.write(line)
        dst.flush()


def main(argv: list[str]) -> int:
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        print("doppler-mask: commande manquante", file=sys.stderr)
        return 64
    values = secret_values()
    pattern = re.compile("|".join(map(re.escape, values))) if values else None
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        print(f"doppler-mask: lancement impossible ({type(exc).__name__})", file=sys.stderr)
        return 127
    threads = [
        threading.Thread(target=pump, args=(proc.stdout, sys.stdout, pattern)),
        threading.Thread(target=pump, args=(proc.stderr, sys.stderr, pattern)),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return proc.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
