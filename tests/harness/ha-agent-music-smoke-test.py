#!/usr/bin/env python3
"""PRD-79: ha-agent-music-smoke against a fake HA WebSocket server (no network, no token)."""

import base64
import hashlib
import json
import os
import socketserver
import struct
import subprocess
import sys
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "k8s/applications/automation/hassio/ha-agent-music-smoke.py"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TOKEN = "fixture-agent-token-cccc"
ENT = "media_player.bureau"


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
    return b1 & 0x0F, bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(sock, n)))


def send_text(sock, obj):
    data = json.dumps(obj).encode()
    head = bytes([0x81])
    head += bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack(">H", len(data))
    sock.sendall(head + data)


class FakeHA:
    def __init__(self, user, admin_allowed=False, volume=0.35, no_track=False, never_plays=False):
        self.user, self.admin_allowed, self.no_track, self.never_plays = user, admin_allowed, no_track, never_plays
        self.volume, self.state, self.title = volume, "idle", None
        self.calls, self.volumes = [], []
        ha = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                s = self.request
                req = b""
                while b"\r\n\r\n" not in req:
                    req += s.recv(4096)
                key = [l.split(": ")[1] for l in req.decode().split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
                acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
                s.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Accept: {acc}\r\n\r\n").encode())
                send_text(s, {"type": "auth_required"})
                try:
                    while True:
                        op, data = read_frame(s)
                        if op == 8:
                            return
                        msg = json.loads(data)
                        if msg["type"] == "auth":
                            if msg["access_token"] != TOKEN:
                                send_text(s, {"type": "auth_invalid"})
                                return
                            send_text(s, {"type": "auth_ok"})
                            continue
                        result, err = ha.dispatch(msg)
                        out = {"id": msg["id"], "type": "result", "success": err is None}
                        out["result" if err is None else "error"] = result if err is None else err
                        send_text(s, out)
                except EOFError:
                    return

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def dispatch(self, msg):
        t = msg["type"]
        self.calls.append(t if t != "call_service" else f"{msg['domain']}.{msg['service']}")
        if t == "auth/current_user":
            return self.user, None
        if t == "config/auth/list":
            return ([], None) if self.admin_allowed else (None, {"code": "unauthorized"})
        if t == "get_states":
            attrs = {"volume_level": self.volume}
            if self.title:
                attrs["media_title"] = self.title
            return [{"entity_id": "light.x", "state": "on", "attributes": {}},
                    {"entity_id": ENT, "state": self.state, "attributes": attrs}], None
        if t == "call_service":
            d, sv, data = msg["domain"], msg["service"], msg["service_data"]
            if (d, sv) == ("media_player", "volume_set"):
                assert msg["target"]["entity_id"] == ENT
                self.volume = data["volume_level"]
                self.volumes.append(self.volume)
            elif (d, sv) == ("music_assistant", "search"):
                assert msg["return_response"] is True
                assert data["config_entry_id"] == "01M86N7DVAGV4K70282V56KQ3Y"
                assert data["media_type"] == ["track"] and data["limit"] == 1 and data["name"] == "love"
                tracks = [] if self.no_track else [{"uri": "jellyfin://track/1", "name": "Love"}]
                return {"context": {}, "response": {"tracks": tracks}}, None
            elif (d, sv) == ("script", "maison_musique_jouer"):
                assert data["enceinte"] == ENT and data["recherche"] == "jellyfin://track/1"
                if not self.never_plays:
                    self.state, self.title = "playing", "Love"
            elif (d, sv) == ("media_player", "media_pause"):
                self.state = "paused"
            else:
                return {"code": "unknown_command"}, {"code": "unknown_command"}
            return {"context": {}}, None
        return {"code": "unknown_command"}, {"code": "unknown_command"}


def run(ha, token=TOKEN, **env):
    e = {"PATH": os.environ.get("PATH", ""), "HA_URL": f"http://127.0.0.1:{ha.port}", "HA_AGENT_TOKEN": token,
         "WAIT_SECONDS": "3", "LISTEN_SECONDS": "0.2", **env}
    p = subprocess.run([sys.executable, "-I", str(SCRIPT)], env=e, capture_output=True, text=True, timeout=30)
    lines = p.stdout.strip().splitlines()
    assert len(lines) == 1, p.stdout + p.stderr
    assert TOKEN not in p.stdout + p.stderr
    return p.returncode, json.loads(lines[0])


AGENT = {"name": "agent-maison", "is_admin": False}


class SmokeTest(unittest.TestCase):
    def test_pass(self):
        ha = FakeHA(AGENT)
        rc, out = run(ha)
        self.assertEqual(rc, 0, out)
        self.assertEqual((out["user"], out["is_admin"], out["admin_ws_denied"]), ("agent-maison", False, True))
        self.assertEqual((out["state"], out["media_title"], out["restored_volume"], out["result"]),
                         ("playing", "Love", 0.35, "PASS"))
        self.assertEqual(ha.volumes, [0.2, 0.35])
        self.assertEqual(ha.state, "paused")

    def test_admin_user_stops_before_any_media_call(self):
        ha = FakeHA({"name": "agent-maison", "is_admin": True})
        rc, out = run(ha)
        self.assertEqual((rc, out["result"]), (1, "FAIL"))
        self.assertFalse(any(c.startswith(("media_player", "script", "music_assistant")) for c in ha.calls), ha.calls)

    def test_wrong_user(self):
        rc, out = run(FakeHA({"name": "paul", "is_admin": False}))
        self.assertEqual((rc, out["result"]), (1, "FAIL"))

    def test_admin_ws_allowed_fails(self):
        ha = FakeHA(AGENT, admin_allowed=True)
        rc, out = run(ha)
        self.assertEqual((rc, out["admin_ws_denied"], out["result"]), (1, False, "FAIL"))
        self.assertNotIn("script.maison_musique_jouer", ha.calls)

    def test_no_track_restores_volume(self):
        ha = FakeHA(AGENT, no_track=True)
        rc, out = run(ha)
        self.assertEqual((rc, out["result"]), (1, "FAIL"))
        self.assertEqual(ha.volumes[-1], 0.35)
        self.assertIn("media_player.media_pause", ha.calls)

    def test_never_plays_fails_and_restores(self):
        ha = FakeHA(AGENT, never_plays=True)
        rc, out = run(ha)
        self.assertEqual((rc, out["result"]), (1, "FAIL"))
        self.assertEqual(ha.volumes[-1], 0.35)

    def test_enceinte_allowlist(self):
        ha = FakeHA(AGENT)
        rc, out = run(ha, ENCEINTE="media_player.cuisine")
        self.assertEqual((rc, out["result"]), (1, "FAIL"))
        self.assertEqual(ha.calls, [])

    def test_bad_token(self):
        rc, out = run(FakeHA(AGENT), token="wrong")
        self.assertEqual((rc, out["result"]), (1, "FAIL"))


if __name__ == "__main__":
    unittest.main()
