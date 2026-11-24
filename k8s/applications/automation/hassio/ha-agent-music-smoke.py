#!/usr/bin/env python3
"""PRD-79: prove from the cluster that the HA user agent-maison (non admin) plays a track.

Stdlib only. The token comes from the environment (HA_AGENT_TOKEN) and is never printed.
Steps: auth/current_user must be the non-admin agent-maison; config/auth/list (admin only)
must be refused; set the volume to 0.20 (cap 0.25); music_assistant.search then the script
maison_musique_jouer; wait for playing + media_title; listen; pause and restore the volume
in a finally. Prints ONE JSON line (no token); exit 0 only if everything passed.
"""

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
from urllib.parse import urlparse

HA_URL = os.environ.get("HA_URL", "http://10.0.20.60:8123")
EXPECTED_USER = os.environ.get("EXPECTED_USER", "agent-maison")
ENCEINTES = ("media_player.bureau", "media_player.salon")
ENCEINTE = os.environ.get("ENCEINTE", "media_player.bureau")
CONFIG_ENTRY_ID = os.environ.get("MA_CONFIG_ENTRY_ID", "01M86N7DVAGV4K70282V56KQ3Y")
QUERY = os.environ.get("QUERY", "love")
WAIT_SECONDS = float(os.environ.get("WAIT_SECONDS", "20"))
LISTEN_SECONDS = float(os.environ.get("LISTEN_SECONDS", "10"))
TEST_VOLUME = 0.20
VOLUME_CAP = 0.25
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class SmokeError(Exception):
    def __init__(self, msg: str, code: str = "") -> None:
        super().__init__(msg)
        self.code = code


class WebSocket:
    """Minimal RFC 6455 text client (no extensions, no TLS: HA is plain HTTP on the LAN)."""

    def __init__(self, url: str, timeout: float = 15.0) -> None:
        u = urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET /api/websocket HTTP/1.1\r\nHost: {u.hostname}:{u.port or 80}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SmokeError("websocket handshake closed")
            head += chunk
            if len(head) > 16384:
                raise SmokeError("websocket handshake too large")
        head, self.buf = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise SmokeError("websocket handshake refused: " + lines[0])
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if f"sec-websocket-accept: {accept}".lower() not in [x.lower() for x in lines]:
            raise SmokeError("websocket accept header mismatch")

    def _read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SmokeError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def send_json(self, obj: dict) -> None:
        self._send_frame(1, json.dumps(obj).encode())

    def recv_json(self) -> dict:
        data = b""
        while True:
            b1, b2 = self._read(2)
            opcode, fin = b1 & 0x0F, b1 & 0x80
            n = b2 & 0x7F
            if n == 126:
                (n,) = struct.unpack(">H", self._read(2))
            elif n == 127:
                (n,) = struct.unpack(">Q", self._read(8))
            payload = self._read(n)
            if opcode == 8:
                raise SmokeError("websocket closed by server")
            if opcode == 9:
                self._send_frame(10, payload)
                continue
            if opcode in (1, 0):
                data += payload
                if fin:
                    return json.loads(data.decode())

    def close(self) -> None:
        try:
            self._send_frame(8, b"")
        except OSError:
            pass
        self.sock.close()


class HA:
    def __init__(self, token: str) -> None:
        self.ws = WebSocket(HA_URL)
        self.seq = 0
        msg = self.ws.recv_json()
        if msg.get("type") != "auth_required":
            raise SmokeError("unexpected first websocket message")
        self.ws.send_json({"type": "auth", "access_token": token})
        msg = self.ws.recv_json()
        if msg.get("type") != "auth_ok":
            raise SmokeError("Home Assistant refused the token (" + str(msg.get("type")) + ")")

    def call(self, **cmd):
        self.seq += 1
        self.ws.send_json({"id": self.seq, **cmd})
        while True:
            msg = self.ws.recv_json()
            if msg.get("id") == self.seq and msg.get("type") == "result":
                if not msg.get("success"):
                    err = msg.get("error") or {}
                    code = str(err.get("code", "unknown"))
                    raise SmokeError(f"{cmd['type']} failed: {code}", code)
                return msg.get("result")

    def service(self, domain: str, service: str, data: dict, target: dict | None = None, response: bool = False):
        cmd = {"type": "call_service", "domain": domain, "service": service, "service_data": data}
        if target:
            cmd["target"] = target
        if response:
            cmd["return_response"] = True
        return self.call(**cmd)

    def state(self, entity_id: str) -> dict:
        for st in self.call(type="get_states"):
            if st.get("entity_id") == entity_id:
                return st
        raise SmokeError(f"entity not found: {entity_id}")

    def close(self) -> None:
        self.ws.close()


def set_volume(ha: HA, level: float, capped: bool = True) -> None:
    if capped and level > VOLUME_CAP:
        raise SmokeError(f"volume {level} above cap {VOLUME_CAP}")
    ha.service("media_player", "volume_set", {"volume_level": level}, {"entity_id": ENCEINTE})


def first_uri(resp) -> str:
    """music_assistant.search returns {tracks: [{uri, name, ...}]} (under 'response' when wrapped)."""
    if isinstance(resp, dict) and isinstance(resp.get("response"), dict):
        resp = resp["response"]
    tracks = (resp or {}).get("tracks") or []
    if not tracks or not tracks[0].get("uri"):
        raise SmokeError("music_assistant.search returned no track")
    return str(tracks[0]["uri"])


def run(token: str, out: dict) -> None:
    ha = HA(token)
    original = None
    touched = False
    try:
        user = ha.call(type="auth/current_user")
        out["user"], out["is_admin"] = user.get("name"), user.get("is_admin")
        if user.get("name") != EXPECTED_USER or user.get("is_admin") is not False:
            raise SmokeError(f"user is not the expected non-admin {EXPECTED_USER}")

        try:
            ha.call(type="config/auth/list")
            out["admin_ws_denied"] = False
        except SmokeError as e:
            out["admin_ws_denied"] = e.code == "unauthorized"
        if not out["admin_ws_denied"]:
            raise SmokeError("config/auth/list was not refused with unauthorized")

        original = ha.state(ENCEINTE).get("attributes", {}).get("volume_level")
        out["original_volume"] = original
        touched = True
        set_volume(ha, TEST_VOLUME)

        found = ha.service(
            "music_assistant", "search",
            {"config_entry_id": CONFIG_ENTRY_ID, "media_type": ["track"], "limit": 1, "name": QUERY},
            response=True,
        )
        uri = first_uri(found)
        ha.service(
            "script", "maison_musique_jouer",
            {"enceinte": ENCEINTE, "recherche": uri, "type": "track", "mode": "replace", "radio": False},
        )

        deadline = time.monotonic() + WAIT_SECONDS
        while True:
            st = ha.state(ENCEINTE)
            out["state"] = st.get("state")
            out["media_title"] = (st.get("attributes") or {}).get("media_title")
            if out["state"] == "playing" and out["media_title"]:
                break
            if time.monotonic() >= deadline:
                raise SmokeError("no playing state with media_title within the delay")
            time.sleep(1)
        time.sleep(LISTEN_SECONDS)
    finally:
        try:
            if touched:
                ha.service("media_player", "media_pause", {}, {"entity_id": ENCEINTE})
                if original is not None:
                    set_volume(ha, float(original), capped=False)
                    # L'état Sonos suit la commande avec un léger retard : on relit jusqu'à 8 s.
                    for _ in range(8):
                        time.sleep(1)
                        out["restored_volume"] = ha.state(ENCEINTE).get("attributes", {}).get("volume_level")
                        if out["restored_volume"] == original:
                            break
        except Exception as e:  # noqa: BLE001 - report, do not mask the primary error
            out["cleanup_error"] = str(e)
        ha.close()


def main() -> int:
    out = {"user": None, "is_admin": None, "admin_ws_denied": None, "state": None,
           "media_title": None, "restored_volume": None}
    token = os.environ.get("HA_AGENT_TOKEN", "")
    ok = False
    try:
        if ENCEINTE not in ENCEINTES:
            raise SmokeError("ENCEINTE must be one of " + ", ".join(ENCEINTES))
        if not token:
            raise SmokeError("HA_AGENT_TOKEN is empty")
        run(token, out)
        ok = "cleanup_error" not in out
        if ok and out.get("original_volume") is not None:
            ok = out.get("restored_volume") == out["original_volume"]
            if not ok:
                out["error"] = "volume not restored"
    except (SmokeError, OSError, ValueError) as e:
        out["error"] = str(e).replace(token, "***") if token else str(e)
    out.pop("original_volume", None)
    out["result"] = "PASS" if ok else "FAIL"
    print(json.dumps(out), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
