#!/usr/bin/env python3
"""stdio <-> Streamable HTTP bridge for one MCP server (stdlib only).

Usage: MCP_BRIDGE_URL=http://127.0.0.1:13030/mcp MCP_BRIDGE_TOKEN_ENV=NAME \
       python3 -I scripts/lib/mcp-http-bridge.py

Reads one JSON-RPC message per stdin line, POSTs it with
`Authorization: Bearer $<MCP_BRIDGE_TOKEN_ENV>`, writes each JSON-RPC message of
the reply (JSON body or SSE `data:` events) as one stdout line. The token is
read from the environment and never written anywhere.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ["MCP_BRIDGE_URL"]
TOKEN = os.environ[os.environ["MCP_BRIDGE_TOKEN_ENV"]]
TIMEOUT = float(os.environ.get("MCP_BRIDGE_TIMEOUT", "120"))

state: dict[str, str] = {}


def emit(obj) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def emit_raw(text: str) -> None:
    text = text.strip()
    if not text:
        return
    data = json.loads(text)
    for msg in data if isinstance(data, list) else [data]:
        if isinstance(msg, dict) and isinstance(msg.get("result"), dict):
            version = msg["result"].get("protocolVersion")
            if isinstance(version, str):
                state["protocol"] = version
        emit(msg)


def post(line: str):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {TOKEN}",
    }
    if "session" in state:
        headers["Mcp-Session-Id"] = state["session"]
    if "protocol" in state:
        headers["MCP-Protocol-Version"] = state["protocol"]
    req = urllib.request.Request(URL, data=line.encode(), headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def handle(line: str) -> None:
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        return
    msg_id = msg.get("id") if isinstance(msg, dict) else None
    try:
        with post(line) as resp:
            session = resp.headers.get("Mcp-Session-Id")
            if session:
                state["session"] = session
            ctype = resp.headers.get("Content-Type", "")
            if "text/event-stream" in ctype:
                buf: list[str] = []
                for raw in resp:
                    text = raw.decode("utf-8").rstrip("\r\n")
                    if text.startswith("data:"):
                        buf.append(text[5:].lstrip())
                    elif text == "" and buf:
                        emit_raw("\n".join(buf))
                        buf = []
                if buf:
                    emit_raw("\n".join(buf))
            else:
                emit_raw(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if msg_id is not None:
            emit({"jsonrpc": "2.0", "id": msg_id,
                  "error": {"code": -32000, "message": f"HTTP {err.code} from MCP server"}})
    except Exception as err:  # noqa: BLE001 - report transport failure to the client
        if msg_id is not None:
            emit({"jsonrpc": "2.0", "id": msg_id,
                  "error": {"code": -32000, "message": f"bridge transport error: {type(err).__name__}"}})


def main() -> int:
    for line in sys.stdin:
        if line.strip():
            handle(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
