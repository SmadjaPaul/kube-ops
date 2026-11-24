#!/usr/bin/env python3
"""PRD-80: rotate the long-lived Home Assistant token used by ha-mcp.

Stdlib only. Reads the current token from the native Secret, mints a new
30-day token over the HA WebSocket API, checks it, patches the Secret, then
revokes older ha-mcp-* tokens (the current and the previous one are kept).
PRD-104: after the Secret patch, the new token is also published to Doppler
(HA_AGENT_TOKEN) for consumers outside the cluster (the Mac MCP client). Publication
is skipped with a message when APP_HA_AGENT_DOPPLER_WRITE_TOKEN is absent.
No token value is ever printed.
"""

import base64
import datetime
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse

HA_URL = os.environ.get("HA_URL", "http://10.0.20.60:8123")
EXPECTED_USER = os.environ.get("EXPECTED_USER", "agent-maison")
SECRET_NAME = os.environ.get("SECRET_NAME", "ha-mcp-token")
SECRET_KEY = os.environ.get("SECRET_KEY", "token")
NAMESPACE = os.environ.get("NAMESPACE", "home-assistant")
K8S_API = os.environ.get("K8S_API", "https://kubernetes.default.svc")
SA_DIR = os.environ.get("SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount")
DOPPLER_API = os.environ.get("DOPPLER_API_URL", "https://api.doppler.com")
DOPPLER_PROJECT = os.environ.get("DOPPLER_PROJECT", "cluster")
DOPPLER_CONFIG = os.environ.get("DOPPLER_CONFIG", "prd")
DOPPLER_KEY = "HA_AGENT_TOKEN"
LIFESPAN_DAYS = 30
CLIENT_PREFIX = "ha-mcp-"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class RotateError(Exception):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


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
                raise RotateError("websocket handshake closed")
            head += chunk
            if len(head) > 16384:
                raise RotateError("websocket handshake too large")
        head, self.buf = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise RotateError("websocket handshake refused: " + lines[0])
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if f"sec-websocket-accept: {accept}".lower() not in [x.lower() for x in lines]:
            raise RotateError("websocket accept header mismatch")

    def _read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RotateError("websocket closed")
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
                raise RotateError("websocket closed by server")
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
            raise RotateError("unexpected first websocket message")
        self.ws.send_json({"type": "auth", "access_token": token})
        msg = self.ws.recv_json()
        if msg.get("type") != "auth_ok":
            raise RotateError("Home Assistant refused the token (" + str(msg.get("type")) + ")")

    def call(self, **cmd):
        self.seq += 1
        self.ws.send_json({"id": self.seq, **cmd})
        while True:
            msg = self.ws.recv_json()
            if msg.get("id") == self.seq and msg.get("type") == "result":
                if not msg.get("success"):
                    err = msg.get("error") or {}
                    raise RotateError(f"{cmd['type']} failed: {err.get('code', 'unknown')}")
                return msg.get("result")

    def close(self) -> None:
        self.ws.close()


def check_identity(ha: HA, label: str) -> None:
    user = ha.call(type="auth/current_user")
    if user.get("name") != EXPECTED_USER or user.get("is_admin") is not False:
        raise RotateError(
            f"{label} token: user is not the expected non-admin {EXPECTED_USER} "
            f"(name_match={user.get('name') == EXPECTED_USER}, is_admin={user.get('is_admin')})"
        )


class Kube:
    def __init__(self) -> None:
        with open(os.path.join(SA_DIR, "token")) as f:
            self.bearer = f.read().strip()
        self.ctx = None
        if K8S_API.startswith("https"):
            self.ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
        self.url = f"{K8S_API}/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET_NAME}"

    def _req(self, method: str, body=None, ctype="application/json"):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.bearer)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=15) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            raise RotateError(f"kubernetes API {method} secret/{SECRET_NAME}: HTTP {e.code}") from None

    def read_token(self) -> str:
        enc = (self._req("GET").get("data") or {}).get(SECRET_KEY)
        if not enc:
            raise RotateError(f"secret {SECRET_NAME} has no key {SECRET_KEY}")
        return base64.b64decode(enc).decode().strip()

    def write_token(self, token: str) -> None:
        enc = base64.b64encode(token.encode()).decode()
        self._req("PATCH", {"data": {SECRET_KEY: enc}}, "application/merge-patch+json")


def publish_doppler(token: str) -> bool:
    """Write the new token to Doppler. Return False when disabled; raise RotateError on refusal."""
    auth = os.environ.get("APP_HA_AGENT_DOPPLER_WRITE_TOKEN", "").strip()
    if not auth:
        log("Doppler publication disabled: APP_HA_AGENT_DOPPLER_WRITE_TOKEN not set")
        return False
    body = json.dumps(
        {"project": DOPPLER_PROJECT, "config": DOPPLER_CONFIG, "secrets": {DOPPLER_KEY: token}}
    ).encode()
    req = urllib.request.Request(DOPPLER_API + "/v3/configs/config/secrets", data=body, method="POST")
    req.add_header("Authorization", "Bearer " + auth)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:  # network, TLS, timeout: type only
        raise RotateError("Doppler unreachable (" + type(e).__name__ + ")") from None
    if status != 200:
        raise RotateError(f"Doppler refused the write (HTTP {status})")
    log(f"{DOPPLER_KEY} published to Doppler {DOPPLER_PROJECT}/{DOPPLER_CONFIG}")
    return True


def parse_ts(value: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def prune(ha: HA, new_client: str) -> int:
    tokens = ha.call(type="auth/refresh_tokens")
    mine = [
        t for t in tokens
        if t.get("type") == "long_lived_access_token"
        and str(t.get("client_name", "")).startswith(CLIENT_PREFIX)
    ]
    current = [t for t in tokens if t.get("is_current")]
    if current:
        floor = parse_ts(current[0]["created_at"])
    else:
        # The current token is not an ha-mcp-* one: keep the two newest ha-mcp-* tokens.
        ordered = sorted(mine, key=lambda t: parse_ts(t["created_at"]), reverse=True)
        if len(ordered) < 2:
            return 0
        floor = parse_ts(ordered[1]["created_at"])
    deleted = 0
    for t in mine:
        if t.get("is_current") or t.get("client_name") == new_client:
            continue
        if parse_ts(t["created_at"]) < floor:
            ha.call(type="auth/delete_refresh_token", refresh_token_id=t["id"])
            deleted += 1
    return deleted


def main() -> int:
    kube = Kube()
    current = kube.read_token()
    ha = HA(current)
    try:
        check_identity(ha, "current")
        client = CLIENT_PREFIX + datetime.date.today().isoformat()
        new = ha.call(
            type="auth/long_lived_access_token", client_name=client, lifespan=LIFESPAN_DAYS
        )
        if not isinstance(new, str) or not new:
            raise RotateError("Home Assistant returned no token")
        # Check before writing: the new token must authenticate as the same restricted user.
        probe = HA(new)
        try:
            check_identity(probe, "new")
        finally:
            probe.close()
        kube.write_token(new)
        log(f"secret {SECRET_NAME} patched with new token {client}")
        # The Secret is the source of truth: a Doppler failure never blocks the pruning,
        # but it fails the job (alert) so that the stale Doppler copy gets noticed.
        publish_error = None
        try:
            publish_doppler(new)
        except RotateError as e:
            publish_error = e
        log(f"revoked {prune(ha, client)} older ha-mcp-* token(s)")
        if publish_error:
            raise publish_error
    finally:
        ha.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RotateError as e:
        log("ERROR: " + str(e))
        sys.exit(1)
    except Exception as e:  # never echo exception text: it could embed request data
        log("ERROR: unexpected " + type(e).__name__)
        sys.exit(1)
