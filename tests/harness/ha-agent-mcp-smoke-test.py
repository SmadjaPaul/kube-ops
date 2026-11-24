#!/usr/bin/env python3
"""PRD-104: ha-agent-mcp-smoke against a fake HA MCP endpoint (no network, no token)."""

import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "k8s/applications/automation/hassio/ha-agent-mcp-smoke.py"
TOKEN = "fixture-agent-token-dddd"
TOOLS = [
    {"name": "HassTurnOn", "inputSchema": {"properties": {"name": {}}}, "annotations": {"readOnlyHint": False}},
    {"name": "GetLiveContext", "inputSchema": {"properties": {}}, "annotations": {"readOnlyHint": True}},
]


class FakeHA:
    def __init__(self, anonymous_ok=False, tools=None, live_error=False):
        self.anonymous_ok, self.tools, self.live_error = anonymous_ok, TOOLS if tools is None else tools, live_error
        self.calls = []
        ha = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj=None):
                data = json.dumps(obj).encode() if obj is not None else b""
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                auth = self.headers.get("Authorization")
                if auth != "Bearer " + TOKEN and not ha.anonymous_ok:
                    return self._send(401)
                if "application/json" not in self.headers.get("Accept", ""):
                    return self._send(400)
                if self.path == "/api/mcp":
                    return self._send(403)
                if self.path != "/api/mcp/assist":
                    return self._send(404)
                ha.calls.append(body["method"])
                rid, m = body["id"], body["method"]
                if m == "initialize":
                    res = {"protocolVersion": "2025-06-18", "serverInfo": {"name": "home-assistant", "version": "x"}}
                elif m == "tools/list":
                    res = {"tools": ha.tools}
                elif m == "tools/call":
                    if body["params"]["name"] != "GetLiveContext":
                        return self._send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -1}})
                    res = {"content": [{"type": "text", "text": "Live Context: salon is idle"}],
                           "isError": ha.live_error}
                else:
                    return self._send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601}})
                self._send(200, {"jsonrpc": "2.0", "id": rid, "result": res})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def run(ha, token=TOKEN):
    env = {"PATH": os.environ.get("PATH", ""), "HA_URL": ha.url, "HA_AGENT_TOKEN": token}
    p = subprocess.run([sys.executable, "-I", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)
    lines = p.stdout.strip().splitlines()
    assert len(lines) == 1, p.stdout + p.stderr
    assert TOKEN not in p.stdout + p.stderr
    return p.returncode, json.loads(lines[0])


class Test(unittest.TestCase):
    def test_pass(self):
        ha = FakeHA()
        try:
            code, out = run(ha)
        finally:
            ha.close()
        self.assertEqual(code, 0, out)
        self.assertEqual(out["result"], "PASS")
        self.assertEqual(out["anonymous_status"], 401)
        self.assertEqual(out["all_apis_status"], 403)
        self.assertEqual(out["tool_count"], 2)
        self.assertEqual(out["call"], "GetLiveContext")
        # Only the read-only tool is called: no action tool, ever.
        self.assertEqual(ha.calls, ["initialize", "tools/list", "tools/call"])

    def test_anonymous_accepted_fails(self):
        ha = FakeHA(anonymous_ok=True)
        try:
            code, out = run(ha)
        finally:
            ha.close()
        self.assertEqual(code, 1)
        self.assertIn("401", out["error"])

    def test_no_live_context_fails(self):
        ha = FakeHA(tools=[TOOLS[0]])
        try:
            code, out = run(ha)
        finally:
            ha.close()
        self.assertEqual(code, 1)
        self.assertNotIn("tools/call", ha.calls)

    def test_wrong_token_fails(self):
        ha = FakeHA()
        try:
            code, out = run(ha, token="other-token-eeee")
        finally:
            ha.close()
        self.assertEqual(code, 1)
        self.assertIn("HTTP 401", out["error"])

    def test_empty_token_fails(self):
        ha = FakeHA()
        try:
            code, out = run(ha, token="")
        finally:
            ha.close()
        self.assertEqual(code, 1)
        self.assertEqual(ha.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
