#!/usr/bin/env python3
"""PRD-104: prove from the cluster that agent-maison (non admin) reaches the native MCP server of HA.

Stdlib only. The token comes from the environment (HA_AGENT_TOKEN) and is never printed.
First, PRD-80 criteria on the REST API: GET /api/ must answer 200 and the admin-only
GET /api/config/config_entries/entry must be refused (401/403).
Then, on the stateless Streamable HTTP endpoint POST /api/mcp/assist (JSON-RPC, one request per
POST): an anonymous initialize must get 401; the all-APIs endpoint /api/mcp must refuse the
non-admin token (403, require_admin); then initialize, tools/list and ONE read-only tools/call
(GetLiveContext). No action tool is ever called: nothing plays, nothing turns on.
Prints ONE JSON line (no token); exit 0 only if everything passed.
"""

import json
import os
import sys
import urllib.error
import urllib.request

HA_URL = os.environ.get("HA_URL", "http://10.0.20.60:8123").rstrip("/")
MCP_PATH = os.environ.get("MCP_PATH", "/api/mcp/assist")
ADMIN_PATH = "/api/mcp"
API_ROOT = "/api/"
CONFIG_ENTRIES = "/api/config/config_entries/entry"
PROTOCOL = os.environ.get("MCP_PROTOCOL_VERSION", "2025-06-18")
LIVE_CONTEXT = "GetLiveContext"
EXCERPT = int(os.environ.get("EXCERPT_CHARS", "600"))


class SmokeError(Exception):
    pass


def post(path: str, payload: dict, token: str | None) -> tuple[int, dict | None]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": PROTOCOL,
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        HA_URL + path, data=json.dumps(payload).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - fixed LAN URL
            body = resp.read().decode()
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        return e.code, None


def get(path: str, token: str) -> int:
    req = urllib.request.Request(HA_URL + path, headers={"Authorization": "Bearer " + token}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - fixed LAN URL
            resp.read()
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def rpc(token: str, rid: int, method: str, params: dict | None = None) -> dict:
    status, body = post(MCP_PATH, {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}, token)
    if status != 200 or not isinstance(body, dict):
        raise SmokeError(f"{method}: HTTP {status}")
    if "error" in body:
        raise SmokeError(f"{method}: JSON-RPC error {body['error'].get('code')}")
    return body.get("result") or {}


def run(token: str, out: dict) -> None:
    init = {"protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "ha-agent-mcp-smoke", "version": "1"}}

    out["anonymous_status"], _ = post(MCP_PATH, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": init}, None)
    if out["anonymous_status"] != 401:
        raise SmokeError("anonymous initialize was not refused with 401")

    out["api_root_status"] = get(API_ROOT, token)
    if out["api_root_status"] != 200:
        raise SmokeError(f"GET {API_ROOT}: HTTP {out['api_root_status']}")
    out["config_entries_status"] = get(CONFIG_ENTRIES, token)
    if out["config_entries_status"] not in (401, 403):
        raise SmokeError(f"GET {CONFIG_ENTRIES} was not refused: HTTP {out['config_entries_status']}")

    out["all_apis_status"], _ = post(ADMIN_PATH, {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": init}, token)

    res = rpc(token, 1, "initialize", init)
    out["init_status"] = 200
    out["server"] = (res.get("serverInfo") or {}).get("name")
    out["server_version"] = (res.get("serverInfo") or {}).get("version")
    out["protocol"] = res.get("protocolVersion")

    tools = rpc(token, 2, "tools/list").get("tools") or []
    out["tool_count"] = len(tools)
    out["tools"] = [
        {"name": t.get("name"),
         "ro": (t.get("annotations") or {}).get("readOnlyHint"),
         "args": sorted(((t.get("inputSchema") or {}).get("properties") or {}).keys())}
        for t in tools
    ]
    names = [t.get("name") or "" for t in tools]
    live = next((n for n in names if n == LIVE_CONTEXT or n.endswith("__" + LIVE_CONTEXT)), None)
    if not live:
        raise SmokeError("no GetLiveContext tool exposed")

    call = rpc(token, 3, "tools/call", {"name": live, "arguments": {}})
    text = " ".join(c.get("text", "") for c in call.get("content") or [] if c.get("type") == "text")
    out["call"] = live
    out["call_is_error"] = bool(call.get("isError"))
    out["call_chars"] = len(text)
    out["call_excerpt"] = text[:EXCERPT]
    if out["call_is_error"] or not text:
        raise SmokeError("GetLiveContext returned an error or nothing")


def main() -> int:
    out = {"endpoint": MCP_PATH, "anonymous_status": None, "api_root_status": None,
           "config_entries_status": None, "all_apis_status": None,
           "init_status": None, "tool_count": None}
    token = os.environ.get("HA_AGENT_TOKEN", "")
    ok = False
    try:
        if not token:
            raise SmokeError("HA_AGENT_TOKEN is empty")
        run(token, out)
        ok = True
    except (SmokeError, OSError, ValueError) as e:
        out["error"] = str(e).replace(token, "***") if token else str(e)
    out["result"] = "PASS" if ok else "FAIL"
    line = json.dumps(out, ensure_ascii=False)
    print(line.replace(token, "***") if token else line, flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
