#!/usr/bin/env python3
"""PRD-80: ha-mcp token rotation against a fake HA WebSocket server and a fake Kubernetes API."""

import base64
import hashlib
import json
import os
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "k8s/applications/automation/hassio/ha-mcp-token-rotate.py"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OLD, NEW = "fixture-old-token-aaaa", "fixture-new-token-bbbb"


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_frame(sock):
    b1, b2 = recv_exact(sock, 2)
    n = b2 & 0x7F
    if n == 126:
        (n,) = struct.unpack(">H", recv_exact(sock, 2))
    mask = recv_exact(sock, 4)
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(sock, n)))
    return b1 & 0x0F, data


def send_text(sock, obj):
    data = json.dumps(obj).encode()
    head = bytes([0x81])
    head += bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack(">H", len(data))
    sock.sendall(head + data)


class FakeHA:
    """users maps token -> user dict; refresh_tokens is what auth/refresh_tokens returns."""

    def __init__(self, users, refresh_tokens, fail_create=False):
        self.users, self.refresh_tokens, self.fail_create = users, refresh_tokens, fail_create
        self.commands = []
        ha = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                s = self.request
                req = b""
                while b"\r\n\r\n" not in req:
                    req += s.recv(4096)
                key = [l.split(": ")[1] for l in req.decode().split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
                acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
                s.sendall(
                    ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     f"Sec-WebSocket-Accept: {acc}\r\n\r\n").encode()
                )
                send_text(s, {"type": "auth_required"})
                user = None
                try:
                    while True:
                        op, data = read_frame(s)
                        if op == 8:
                            return
                        msg = json.loads(data)
                        if msg["type"] == "auth":
                            user = ha.users.get(msg["access_token"])
                            if user is None:
                                send_text(s, {"type": "auth_invalid"})
                                return
                            send_text(s, {"type": "auth_ok"})
                            continue
                        ha.commands.append(msg["type"])
                        result, ok = ha.dispatch(msg, user)
                        out = {"id": msg["id"], "type": "result", "success": ok}
                        out["result" if ok else "error"] = result
                        send_text(s, out)
                except EOFError:
                    return

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def dispatch(self, msg, user):
        t = msg["type"]
        if t == "auth/current_user":
            return user, True
        if t == "auth/long_lived_access_token":
            if self.fail_create:
                return {"code": "unknown_error"}, False
            assert msg["lifespan"] == 30 and msg["client_name"].startswith("ha-mcp-")
            self.users[NEW] = user
            return NEW, True
        if t == "auth/refresh_tokens":
            return self.refresh_tokens, True
        if t == "auth/delete_refresh_token":
            self.refresh_tokens[:] = [r for r in self.refresh_tokens if r["id"] != msg["refresh_token_id"]]
            return None, True
        return {"code": "unknown_command"}, False


class FakeKube:
    def __init__(self):
        self.writes = []
        kube = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                body = json.dumps({"data": {"token": base64.b64encode(OLD.encode()).decode()}}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def do_PATCH(self):
                n = int(self.headers["Content-Length"])
                kube.writes.append((self.headers["Content-Type"], json.loads(self.rfile.read(n))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


class FakeDoppler:
    def __init__(self, status=200):
        self.writes = []
        doppler = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers["Content-Length"])
                doppler.writes.append(
                    (self.path, self.headers["Authorization"], json.loads(self.rfile.read(n)))
                )
                self.send_response(status)
                self.end_headers()
                self.wfile.write(b"{}")

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def rt(i, name, created, current=False, kind="long_lived_access_token"):
    return {"id": i, "client_name": name, "type": kind, "created_at": created, "is_current": current}


AGENT = {"name": "agent-maison", "is_admin": False, "is_owner": False}
REFRESH = [
    rt("r1", "ha-mcp-2026-10-01", "2026-10-01T04:00:00+00:00"),  # older than previous: revoked
    rt("r2", "ha-mcp-2026-11-09", "2026-11-09T04:00:00+00:00"),  # previous... older than current: revoked
    rt("r3", "ha-mcp-2026-11-16", "2026-11-16T04:00:00+00:00", current=True),  # current: kept
    rt("r4", "manual-other", "2026-09-01T04:00:00+00:00"),  # not ha-mcp-*: kept
    rt("r5", "ha-mcp-web", "2026-09-01T04:00:00+00:00", kind="normal"),  # not long-lived: kept
    rt("r6", "ha-mcp-2026-11-23", "2026-11-23T04:00:00+00:00"),  # the new one: kept
]


class RotateTest(unittest.TestCase):
    def run_script(self, ha, kube, doppler=None, write_token="fixture-doppler-write"):
        with tempfile.TemporaryDirectory() as sa:
            Path(sa, "token").write_text("fixture-sa-bearer")
            env = {
                "PATH": os.environ["PATH"], "SA_DIR": sa,
                "HA_URL": f"http://127.0.0.1:{ha.port}",
                "K8S_API": f"http://127.0.0.1:{kube.port}",
            }
            if doppler is not None:
                env["DOPPLER_API_URL"] = f"http://127.0.0.1:{doppler.port}"
                env["APP_HA_AGENT_DOPPLER_WRITE_TOKEN"] = write_token
            p = subprocess.run([sys.executable, "-I", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
        out = p.stdout + p.stderr
        for secret in (OLD, NEW, "fixture-sa-bearer", "fixture-doppler-write"):
            self.assertNotIn(secret, out, "token value leaked in logs")
        return p

    def test_nominal_rotation_patches_secret_and_prunes_old_tokens(self):
        ha, kube = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH]), FakeKube()
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(len(kube.writes), 1)
        ctype, body = kube.writes[0]
        self.assertEqual(ctype, "application/merge-patch+json")
        self.assertEqual(base64.b64decode(body["data"]["token"]).decode(), NEW)
        self.assertEqual(sorted(r["id"] for r in ha.refresh_tokens), ["r3", "r4", "r5", "r6"])

    def test_publishes_new_token_to_doppler_after_secret_patch(self):
        ha, kube, dop = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH]), FakeKube(), FakeDoppler()
        p = self.run_script(ha, kube, dop)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(len(kube.writes), 1)
        self.assertEqual(len(dop.writes), 1)
        path, auth, body = dop.writes[0]
        self.assertEqual(path, "/v3/configs/config/secrets")
        self.assertEqual(auth, "Bearer fixture-doppler-write")
        self.assertEqual(body, {"project": "cluster", "config": "prd", "secrets": {"HA_AGENT_TOKEN": NEW}})

    def test_missing_doppler_write_token_disables_publication_only(self):
        ha, kube, dop = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH]), FakeKube(), FakeDoppler()
        p = self.run_script(ha, kube, dop, write_token="")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("publication disabled", p.stdout)
        self.assertEqual(dop.writes, [])
        self.assertEqual(len(kube.writes), 1)
        self.assertEqual(sorted(r["id"] for r in ha.refresh_tokens), ["r3", "r4", "r5", "r6"])

    def test_doppler_refusal_fails_job_but_secret_and_pruning_are_done(self):
        ha, kube, dop = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH]), FakeKube(), FakeDoppler(403)
        p = self.run_script(ha, kube, dop)
        self.assertEqual(p.returncode, 1)
        self.assertIn("HTTP 403", p.stdout)
        self.assertEqual(len(kube.writes), 1)
        self.assertEqual(sorted(r["id"] for r in ha.refresh_tokens), ["r3", "r4", "r5", "r6"])

    def test_no_doppler_write_when_rotation_fails_before_secret_patch(self):
        ha, kube, dop = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH], fail_create=True), FakeKube(), FakeDoppler()
        p = self.run_script(ha, kube, dop)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(dop.writes, [])

    def test_admin_user_is_refused_before_any_write(self):
        ha, kube = FakeHA({OLD: {"name": "agent-maison", "is_admin": True}}, [dict(r) for r in REFRESH]), FakeKube()
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(kube.writes, [])
        self.assertNotIn("auth/long_lived_access_token", ha.commands)

    def test_wrong_user_is_refused_before_any_write(self):
        ha, kube = FakeHA({OLD: {"name": "paul", "is_admin": False}}, [dict(r) for r in REFRESH]), FakeKube()
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(kube.writes, [])
        self.assertNotIn("auth/long_lived_access_token", ha.commands)

    def test_create_failure_writes_nothing_and_revokes_nothing(self):
        ha, kube = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH], fail_create=True), FakeKube()
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(kube.writes, [])
        self.assertNotIn("auth/delete_refresh_token", ha.commands)

    def test_new_token_with_wrong_identity_writes_nothing(self):
        ha, kube = FakeHA({OLD: dict(AGENT)}, [dict(r) for r in REFRESH]), FakeKube()
        orig = ha.dispatch

        def dispatch(msg, user):
            if msg["type"] == "auth/long_lived_access_token":
                ha.users[NEW] = {"name": "agent-maison", "is_admin": True}
                return NEW, True
            return orig(msg, user)

        ha.dispatch = dispatch
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(kube.writes, [])
        self.assertNotIn("auth/delete_refresh_token", ha.commands)

    def test_rejected_current_token_fails_without_write(self):
        ha, kube = FakeHA({}, [dict(r) for r in REFRESH]), FakeKube()
        p = self.run_script(ha, kube)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(kube.writes, [])


if __name__ == "__main__":
    unittest.main()
