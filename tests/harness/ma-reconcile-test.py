#!/usr/bin/env python3
"""PRD-83 : tests de ma_reconcile.py contre un faux Music Assistant avec etat (fixtures JSON).
Aucun acces reseau externe : serveur HTTP local sur port ephemere."""

import contextlib
import copy
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "k8s/applications/automation/music-assistant/reconcile")
FIX = os.path.join(ROOT, "tests/fixtures/ma-reconcile")
spec = importlib.util.spec_from_file_location("ma_reconcile", os.path.join(APP, "ma_reconcile.py"))
ma = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ma)

CANARY = "S3CR3T-CANARY-PASSWORD"
TOKEN = "T0KEN-CANARY"
ENV = {"APP_MA_RECONCILE_TOKEN": TOKEN, "APP_MA_POLYFIN_PASSWORD": CANARY}


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


# Signatures REELLES de MA 2.10.8 (music_assistant/controllers/config/*.py, webserver/auth.py) :
# commande -> (arguments obligatoires, arguments facultatifs). Un argument manquant ou inconnu
# donne un HTTP 500 comme sur la vraie instance ; une commande inconnue un HTTP 400.
SIGNATURES = {
    "config/core/get": (("domain",), ()),
    "config/core/save": (("domain", "values"), ()),
    "config/providers": ((), ("provider_type", "provider_domain", "include_values")),
    "config/providers/get": (("instance_id",), ()),
    "config/providers/save": (("provider_domain", "values"), ("instance_id",)),
    "config/providers/remove": (("instance_id",), ()),
    "config/providers/setup": (("provider_domain",), ()),
    "config/flows/submit": (("flow_id", "values"), ()),
    "config/flows/get": (("flow_id",), ()),
    "config/players": ((), ("provider", "include_values", "include_unavailable", "include_disabled")),
    "config/players/save": (("player_id", "values"), ()),
    "auth/users": ((), ()),
    "auth/user/create": (("username", "password"), ("role", "display_name")),
    "auth/user/update": ((), ("user_id", "role", "username", "password", "display_name")),
}
FORM_ENTRIES = {
    "jellyfin": ["url", "username", "password", "verify_ssl"],
}


class FakeMA:
    def __init__(self, state):
        self.state = state
        self.calls = []
        self.flows = {}
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, data=b""):
                self.send_response(code)
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path != "/api":
                    return self.reply(404)
                if self.headers.get("Authorization") != "Bearer " + TOKEN:
                    return self.reply(401)
                cmd, args = body["command"], body.get("args") or {}
                fake.calls.append(cmd)
                if cmd not in SIGNATURES:
                    return self.reply(400, b"Invalid Command: " + cmd.encode())
                required, optional = SIGNATURES[cmd]
                if set(required) - set(args) or set(args) - set(required) - set(optional):
                    return self.reply(500, b"Internal server error")
                try:
                    out = fake.handle(cmd, args)
                except (KeyError, StopIteration):
                    return self.reply(500, b"Internal server error")
                self.reply(200, json.dumps(out).encode())

        self.httpd = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()

    def writes(self):
        return [c for c in self.calls if c.endswith(("save", "setup", "create", "update", "remove", "submit"))]

    def handle(self, cmd, a):
        s = self.state
        if cmd == "config/core/get":
            return s["core"][a["domain"]]
        if cmd == "config/core/save":
            for k, v in a["values"].items():
                s["core"][a["domain"]]["values"][k] = {"value": v}
            return s["core"][a["domain"]]
        if cmd == "config/providers":
            if a.get("include_values"):
                return s["providers"]
            return [{**p, "values": {}} for p in s["providers"]]
        if cmd == "config/providers/get":
            return next(p for p in s["providers"] if p["instance_id"] == a["instance_id"])
        if cmd == "config/providers/setup":
            dom = a["provider_domain"]
            if dom not in FORM_ENTRIES:  # sans flux : instance creee vide, etape finish immediate
                s["providers"].append({"instance_id": dom + "--new", "domain": dom, "enabled": True, "values": {}})
                return {"flow_id": "f0", "step_id": "done", "type": "finish", "result": {"instance_id": dom + "--new"}}
            self.flows["f1"] = dom
            entries = [{"key": k, "type": "string"} for k in FORM_ENTRIES[dom]]
            return {"flow_id": "f1", "step_id": "user", "type": "form", "entries": entries, "errors": {}}
        if cmd == "config/flows/submit":
            dom = self.flows[a["flow_id"]]
            if set(a["values"]) - set(FORM_ENTRIES[dom]):
                raise KeyError("champ inconnu")
            vals = {k: {"value": ("$ENC$" if k == "password" else v)} for k, v in a["values"].items()}
            s["providers"].append({"instance_id": dom + "--new", "domain": dom, "enabled": True, "values": vals})
            return {"flow_id": a["flow_id"], "step_id": "done", "type": "finish", "result": {"instance_id": dom + "--new"}}
        if cmd == "config/providers/save":
            p = next(x for x in s["providers"] if x["instance_id"] == a["instance_id"])
            for k, v in a["values"].items():
                if k == "enabled":
                    p["enabled"] = v
                else:
                    p["values"][k] = {"value": v}
            return p
        if cmd == "config/providers/remove":
            s["providers"] = [x for x in s["providers"] if x["instance_id"] != a["instance_id"]]
            return None
        if cmd == "config/players":
            return s["players"]
        if cmd == "config/players/save":
            p = next(x for x in s["players"] if x["player_id"] == a["player_id"])
            for k, v in a["values"].items():
                p["values"][k] = {"value": v}
            return p
        if cmd == "auth/users":
            return s["users"]
        if cmd == "auth/user/create":
            u = {"user_id": "new-" + a["username"], "username": a["username"], "role": a.get("role", "user")}
            s["users"].append(u)
            return u
        if cmd == "auth/user/update":
            u = next(u for u in s["users"] if u["user_id"] == a["user_id"])
            u["role"] = a["role"]
            return u
        raise AssertionError("commande inattendue " + cmd)


def run(argv, env=ENV):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = ma.main(argv, env)
    return code, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def start(self, state_file, desired=None):
        self.fake = FakeMA(fixture(state_file))
        self.addCleanup(self.fake.close)
        return ["--desired", desired or os.path.join(APP, "desired.json"), "--url", self.fake.url]

    def no_leak(self, *texts):
        for t in texts:
            self.assertNotIn(CANARY, t)
            self.assertNotIn(TOKEN, t)


class TestPlan(Base):
    def test_fresh_plan_lists_creates_without_writing(self):
        args = self.start("state-fresh.json")
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_ERROR)  # utilisateurs svc-* absents : bloques
        self.assertIn("+ provider/sonos create", out)
        self.assertIn("+ provider/jellyfin create", out)
        self.assertIn('publish_ip: null -> "10.0.20.192"', out)
        self.assertIn("! user/svc-ma-reconcile blocked", out)
        self.assertEqual(self.fake.writes(), [])
        self.no_leak(out, err)

    def test_converged_plan_is_empty(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertNotIn("update", out)
        self.assertNotIn("create", out)
        self.assertIn("? provider/builtin undeclared", out)
        self.assertEqual(self.fake.writes(), [])
        self.no_leak(out, err)

    def test_drift_detected(self):
        args = self.start("state-converged.json")
        self.fake.state["core"]["streams"]["values"]["publish_ip"] = {"value": "1.2.3.4"}
        self.fake.state["providers"][1]["values"]["manual_discovery_ip_addresses"] = {"value": ["10.0.35.11"]}
        self.fake.state["users"][2]["role"] = "user"
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_DRIFT)
        self.assertIn("~ core/streams update", out)
        self.assertIn("~ provider/sonos update", out)
        self.assertIn("~ user/svc-home-assistant update", out)
        self.assertEqual(self.fake.writes(), [])


class TestApply(Base):
    def test_apply_is_idempotent_and_restores_drift(self):
        args = self.start("state-converged.json")
        self.fake.state["core"]["streams"]["values"]["publish_ip"] = {"value": "1.2.3.4"}
        self.fake.state["providers"] = [p for p in self.fake.state["providers"] if p["domain"] != "chromecast"]
        self.fake.state["users"][2]["role"] = "user"
        code, out, err = run(["--apply"] + args)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertEqual(self.fake.state["core"]["streams"]["values"]["publish_ip"]["value"], "10.0.20.192")
        self.assertTrue(any(p["domain"] == "chromecast" for p in self.fake.state["providers"]))
        self.assertEqual(next(u for u in self.fake.state["users"] if u["username"] == "svc-home-assistant")["role"], "service")
        self.no_leak(out, err)
        before = len(self.fake.writes())
        code, out, err = run(["--apply"] + args)
        self.assertEqual(code, ma.EXIT_OK)
        self.assertEqual(len(self.fake.writes()), before)  # deuxieme passage : zero ecriture

    def test_apply_creates_jellyfin_with_secret_never_printed(self):
        args = self.start("state-converged.json")
        self.fake.state["providers"] = [p for p in self.fake.state["providers"] if p["domain"] != "jellyfin"]
        code, out, err = run(["--apply"] + args)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertIn("config/providers/setup", self.fake.calls)
        self.assertIn("config/flows/submit", self.fake.calls)
        self.assertNotIn("config/providers/get", self.fake.calls)  # exige instance_id : jamais en liste
        self.no_leak(out, err)

    def test_secret_is_not_compared_nor_resent_on_update(self):
        args = self.start("state-converged.json")
        self.fake.state["providers"][3]["values"]["username"] = {"value": "autre"}
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_DRIFT)
        self.assertNotIn("password", out)
        self.no_leak(out, err)


class TestRefusals(Base):
    def test_missing_token(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args, env={"APP_MA_POLYFIN_PASSWORD": CANARY})
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertIn("APP_MA_RECONCILE_TOKEN", err)
        self.assertEqual(self.fake.calls, [])

    def test_missing_secret_env(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args, env={"APP_MA_RECONCILE_TOKEN": TOKEN})
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertIn("APP_MA_POLYFIN_PASSWORD", err)

    def test_wrong_token_is_error_without_leak(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args, env={"APP_MA_RECONCILE_TOKEN": "mauvais", "APP_MA_POLYFIN_PASSWORD": CANARY})
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertIn("HTTP 401", err)
        self.no_leak(out, err)

    def test_apply_refused_when_blocked(self):
        args = self.start("state-fresh.json")
        code, out, err = run(["--apply"] + args)
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertEqual(self.fake.writes(), [])

    def test_prune_requires_apply(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan", "--prune"] + args)
        self.assertEqual(code, ma.EXIT_ERROR)

    def test_undeclared_provider_kept_without_prune(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--apply"] + args)
        self.assertEqual(code, ma.EXIT_OK)
        self.assertTrue(any(p["domain"] == "builtin" for p in self.fake.state["providers"]))

    def test_prune_only_in_prune_domains(self):
        args = self.start("state-converged.json")
        self.fake.state["providers"].append({"instance_id": "x--1", "domain": "spotify", "enabled": True, "values": {}})
        self.fake.state["providers"].append({"instance_id": "y--1", "domain": "tidal", "enabled": True, "values": {}})
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(APP, "desired.json"), encoding="utf-8") as f:
                desired = json.load(f)
            desired["prune_domains"] = ["spotify"]
            path = os.path.join(d, "desired.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(desired, f)
            args = ["--desired", path, "--url", self.fake.url]
            code, out, err = run(["--apply", "--prune"] + args)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        domains = {p["domain"] for p in self.fake.state["providers"]}
        self.assertNotIn("spotify", domains)
        self.assertIn("tidal", domains)
        self.assertIn("builtin", domains)

    def test_unknown_player_blocked_and_known_renamed(self):
        args = self.start("state-players.json", os.path.join(FIX, "players-desired.json"))
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertIn("! player/RINCON_ZZZ blocked", out)
        self.assertIn('name: "Sonos Roam" -> "Salon"', out)


class TestDesired(unittest.TestCase):
    def test_desired_has_no_inline_secret_and_expected_values(self):
        with open(os.path.join(APP, "desired.json"), encoding="utf-8") as f:
            d = json.load(f)
        self.assertEqual(d["core"]["streams"], {"publish_ip": "10.0.20.192", "bind_port": 8097})
        sonos = next(p for p in d["providers"] if p["domain"] == "sonos")
        self.assertEqual(
            sonos["values"], {"manual_discovery_ip_addresses": ["10.0.35.11", "10.0.35.50", "10.0.35.53", "10.0.35.54"]}
        )
        jf = next(p for p in d["providers"] if p["domain"] == "jellyfin")
        self.assertEqual(jf["values"]["password"], {"secret_env": "APP_MA_POLYFIN_PASSWORD"})
        self.assertEqual(d["prune_domains"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
