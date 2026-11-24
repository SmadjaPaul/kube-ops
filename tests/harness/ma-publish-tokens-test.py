#!/usr/bin/env python3
"""PRD-84 : tests de ma_publish_tokens.py contre un faux serveur Doppler (port ephemere, aucun reseau externe)."""

import hashlib
import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(ROOT, "k8s/applications/automation/music-assistant/reconcile/ma_publish_tokens.py")
WRITE = "DOPPLER-WRITE-CANARY"
TOKEN = "MA-HA-TOKEN-CANARY"
SHA = hashlib.sha256(TOKEN.encode()).hexdigest()


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, doc):
        raw = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        srv = self.server
        srv.calls.append((self.command, self.path))
        if self.headers.get("Authorization") != "Bearer " + srv.expect:
            self.reply(401, {"success": False, "messages": ["Invalid Auth token " + WRITE + TOKEN]})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path != "/v3/configs/config/secret" or q.get("project") != ["home"] or q.get("config") != ["prd_maison"]:
            return self.reply(400, {"success": False})
        name = q.get("name", [""])[0]
        if name not in self.server.store:
            return self.reply(404, {"success": False, "messages": ["Could not find requested secret"]})
        v = self.server.store[name]
        self.reply(200, {"success": True, "name": name, "value": {"raw": v, "computed": v}})

    def do_POST(self):
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if urlparse(self.path).path != "/v3/configs/config/secrets" or body.get("project") != "home" or body.get("config") != "prd_maison":
            return self.reply(400, {"success": False})
        self.server.posts.append(body)
        self.server.store.update(body["secrets"])
        self.reply(200, {"success": True, "secrets": {}})


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.srv = HTTPServer(("127.0.0.1", 0), Fake)
        self.srv.store, self.srv.posts, self.srv.calls, self.srv.expect = {}, [], [], WRITE
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def run_script(self, token=TOKEN, write=WRITE):
        env = {"PATH": os.environ.get("PATH", ""), "DOPPLER_API_URL": "http://127.0.0.1:%d" % self.srv.server_port}
        if token is not None:
            env["APP_MA_HA_TOKEN"] = token
        if write is not None:
            env["APP_MAISON_DOPPLER_WRITE_TOKEN"] = write
        p = subprocess.run([sys.executable, "-I", SCRIPT], env=env, capture_output=True, text=True, timeout=30)
        out = p.stdout + p.stderr
        for secret in (TOKEN, WRITE, SHA, "token-v2-canary"):
            self.assertNotIn(secret, out, "fuite d'une valeur")
        return p.returncode, out

    def test_nominal_publie_jeton_et_empreinte(self):
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.srv.posts), 1)
        self.assertEqual(self.srv.posts[0]["secrets"], {"MA_HOME_ASSISTANT_TOKEN": TOKEN, "MA_HOME_ASSISTANT_TOKEN_SHA256": SHA})
        self.assertIn("publie", out)

    def test_idempotent_aucune_ecriture_si_empreinte_identique(self):
        self.assertEqual(self.run_script()[0], 0)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.srv.posts), 1)
        self.assertIn("deja a jour", out)

    def test_jeton_renouvele_est_republie(self):
        self.assertEqual(self.run_script()[0], 0)
        new = "token-v2-canary"
        rc, _ = self.run_script(token=new)
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.srv.posts), 2)
        self.assertEqual(self.srv.store["MA_HOME_ASSISTANT_TOKEN"], new)
        self.assertEqual(self.srv.store["MA_HOME_ASSISTANT_TOKEN_SHA256"], hashlib.sha256(new.encode()).hexdigest())

    def test_jeton_ha_absent_ou_vide_aucun_appel(self):
        for tok in (None, "", "  "):
            rc, out = self.run_script(token=tok)
            self.assertEqual(rc, 1)
            self.assertIn("absent", out)
        self.assertEqual(self.srv.calls, [])

    def test_jeton_doppler_absent_aucun_appel(self):
        rc, out = self.run_script(write=None)
        self.assertEqual(rc, 1)
        self.assertIn("absent", out)
        self.assertEqual(self.srv.calls, [])

    def test_refus_401_echoue_sans_fuite(self):
        rc, out = self.run_script(write="mauvais-jeton")
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 401", out)
        self.assertEqual(self.srv.posts, [])

    def test_serveur_injoignable(self):
        self.srv.shutdown()
        self.srv.server_close()
        rc, out = self.run_script()
        self.assertEqual(rc, 1)
        self.assertIn("injoignable", out)


if __name__ == "__main__":
    unittest.main()
