#!/usr/bin/env python3
"""Strict, small Polyfin upstream overlay. Does not modify the active image.

Run from a checked-out EXACT v0.50.0 upstream tree:
  python3 /path/to/kube-ops/.github/polyfin/authbridge/apply.py .

This is intentionally separate from the signed v0.50.0 downstream builder.
It must not be promoted until code review, tests, fresh SBOM/provenance,
Trivy and explicit per-digest risk admission.
"""
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent
TARGET = pathlib.Path(sys.argv[1] if len(sys.argv) == 2 else ".").resolve()
main = TARGET / "cmd/polyfin/main.go"
web = TARGET / "internal/server/webclient.js"
bridge = TARGET / "cmd/polyfin/authbridge.go"

if not main.is_file() or not web.is_file() or not (TARGET / "go.mod").is_file():
    raise SystemExit("FAIL: expected upstream Polyfin source checkout")

original = main.read_text()
before = 'Handler: server.New(server.Options{'
after = 'Handler: withAuthentikBridge(server.New(server.Options{'
ending_before = '\n\t\t}),\n\t\tReadHeaderTimeout: readHeaderTimeout,'
ending_after = '\n\t\t}), store, serverID),\n\t\tReadHeaderTimeout: readHeaderTimeout,'
if original.count(before) != 1 or original.count(ending_before) != 1:
    raise SystemExit("FAIL: upstream main.go changed; rebase the atomic patch, do not guess")

web_original = web.read_text()
frontend = (ROOT / "web-login.js").read_text()
if "polyfin-authentik-login" in web_original or bridge.exists():
    raise SystemExit("FAIL: patch already present; refuse to double-apply")

# Guard against unexpected changes to the target base; no silent fuzzy patch.
if not original.startswith("package main\n") and "package main" not in original[:1000]:
    raise SystemExit("FAIL: unexpected Polyfin entrypoint")
main.write_text(original.replace(before, after, 1).replace(ending_before, ending_after, 1))
shutil.copyfile(ROOT / "authbridge.go", bridge)
shutil.copyfile(ROOT / "authbridge_test.go", TARGET / "cmd/polyfin/authbridge_test.go")
web.write_text(web_original + "\n\n" + frontend)
print("PASS: native-session bridge, focused tests, narrow main.go hook and web login button")
