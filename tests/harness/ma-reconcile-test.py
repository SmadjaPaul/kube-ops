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
import base64
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
STORED = "HA-STORED-CANARY"
ENV = {"APP_MA_RECONCILE_TOKEN": TOKEN, "APP_MA_POLYFIN_PASSWORD": CANARY, "APP_MA_HA_TOKEN": STORED}
HA_TOKEN_ENV = "APP_MA_HA_TOKEN"
HA_SECRET = "ma-home-assistant-token"


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
    "auth/tokens": ((), ("user_id",)),
    "auth/token/create": (("name",), ("user_id",)),
}
# MA 2.10.8 : le fournisseur jellyfin ne declare aucune entree (get_config_entries() == ()), donc
# config/providers(include_values) ne renvoie pas ses valeurs stockees (url, username, password).
UNEXPOSED = {"jellyfin"}
FORM_ENTRIES = {
    "jellyfin": ["url", "username", "password", "verify_ssl"],
}


class FakeMA:
    def __init__(self, state):
        self.state = state
        self.calls = []
        self.flows = {}
        self.issued = {t["value"]: t["user_id"] for t in state.get("tokens", []) if "value" in t}
        self.passwords = []
        self.bearer = None
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
                bearer = (self.headers.get("Authorization") or "")[len("Bearer "):]
                if bearer != TOKEN and bearer not in fake.issued:
                    return self.reply(401)
                fake.bearer = bearer
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
                return [{**p, "values": {} if p["domain"] in UNEXPOSED else p["values"]} for p in s["providers"]]
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
            self.passwords.append(a["password"])
            u = {"user_id": "new-" + a["username"], "username": a["username"], "role": a.get("role", "user")}
            s["users"].append(u)
            return u
        if cmd == "auth/user/update":
            u = next(u for u in s["users"] if u["user_id"] == a["user_id"])
            u["role"] = a["role"]
            return u
        if cmd == "auth/tokens":
            uid = a.get("user_id") or ("u2" if self.bearer == TOKEN else self.issued[self.bearer])
            return [t for t in s.setdefault("tokens", []) if t["user_id"] == uid]
        if cmd == "auth/token/create":
            if self.bearer != TOKEN:  # users.manage : admin seulement pour un autre utilisateur
                raise KeyError
            uid = a.get("user_id", "u2")
            if not any(u["user_id"] == uid for u in s["users"]):
                raise KeyError
            n = sum(1 for t in self.issued if t.startswith("HA-ISSUED")) + 1
            tok = f"HA-ISSUED-CANARY-{n}"
            self.issued[tok] = uid
            s.setdefault("tokens", []).append(
                {"token_id": "t" + str(n), "user_id": uid, "name": a["name"], "is_long_lived": True,
                 "expires_at": s.get("next_expiry", "2099-01-01T00:00:00+00:00")}
            )
            return tok
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
            self.assertNotIn(STORED, t)
            self.assertNotIn("HA-ISSUED-CANARY", t)
            for pw in self.fake.passwords:
                self.assertNotIn(pw, t)


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

    def test_unexposed_provider_values_are_not_drift(self):
        # defaut observe en prod : url/username lus null alors que le fournisseur est charge
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertIn("= provider/jellyfin noop", out)
        self.assertIn("url, username", out)  # la note dit lesquelles ne sont pas verifiables
        self.assertNotIn("null", out)
        self.assertEqual(self.fake.writes(), [])
        self.no_leak(out, err)

    def test_exposed_key_still_drifts(self):
        args = self.start("state-converged.json")
        self.fake.state["providers"][1]["values"]["manual_discovery_ip_addresses"] = {"value": ["10.0.35.11"]}
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_DRIFT)
        self.assertIn("provider/sonos update", out)

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
        self.fake.state["providers"][3]["enabled"] = False
        code, out, err = run(["--plan"] + args)
        self.assertEqual(code, ma.EXIT_DRIFT)
        self.assertIn("provider/jellyfin update", out)
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


class FakeKube:
    """Faux kube-apiserver : accepte seulement PATCH merge d'un Secret precis avec le jeton du ServiceAccount."""

    SA_TOKEN = "SA-CANARY"

    def __init__(self, fail=False):
        self.patches = []
        self.fail = fail
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_PATCH(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                ok = self.headers.get("Authorization") == "Bearer " + FakeKube.SA_TOKEN
                if fake.fail or not ok:
                    self.send_response(403 if not ok else 500)
                    self.end_headers()
                    return
                fake.patches.append((self.path, self.headers.get("Content-Type"), body))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

            def do_GET(self):
                fake.patches.append(("GET " + self.path, None, None))
                self.send_response(500)
                self.end_headers()

        self.httpd = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()


class TestHomeAssistantToken(Base):
    def setUp(self):
        self.sa = tempfile.TemporaryDirectory()
        self.addCleanup(self.sa.cleanup)
        for name, val in (("token", FakeKube.SA_TOKEN), ("namespace", "music-assistant")):
            with open(os.path.join(self.sa.name, name), "w", encoding="utf-8") as f:
                f.write(val)
        self.kube = FakeKube()
        self.addCleanup(self.kube.close)
        self.env = dict(ENV, MA_RECONCILE_KUBE_URL=self.kube.url, MA_RECONCILE_SA_DIR=self.sa.name)

    def expect_secret_patch(self, token):
        self.assertEqual(len(self.kube.patches), 1)
        path, ctype, body = self.kube.patches[0]
        self.assertEqual(path, f"/api/v1/namespaces/music-assistant/secrets/{HA_SECRET}")
        self.assertEqual(ctype, "application/merge-patch+json")
        self.assertEqual(base64.b64decode(body["data"]["token"]).decode(), token)
        self.assertEqual(list(body), ["data"])

    def test_valid_stored_token_is_noop(self):
        args = self.start("state-converged.json")
        code, out, err = run(["--plan"] + args, self.env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertIn("= token/svc-home-assistant noop", out)
        code, out, err = run(["--apply"] + args, self.env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertNotIn("auth/token/create", self.fake.calls)
        self.assertEqual(self.kube.patches, [])

    def test_placeholder_token_is_replaced_and_stored(self):
        args = self.start("state-converged.json")
        env = dict(self.env, APP_MA_HA_TOKEN="placeholder-aleatoire")
        code, out, err = run(["--plan"] + args, env)
        self.assertEqual(code, ma.EXIT_DRIFT, out + err)
        self.assertIn("+ token/svc-home-assistant create", out)
        self.assertEqual(self.kube.patches, [])  # plan : aucune ecriture
        self.assertNotIn("auth/token/create", self.fake.calls)
        code, out, err = run(["--apply"] + args, env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertEqual(self.fake.calls.count("auth/token/create"), 1)
        self.expect_secret_patch("HA-ISSUED-CANARY-1")
        self.no_leak(out, err)
        self.assertNotIn("placeholder-aleatoire", out + err)

    def test_absent_env_token_is_issued(self):
        args = self.start("state-converged.json")
        env = {k: v for k, v in self.env.items() if k != HA_TOKEN_ENV}
        code, out, err = run(["--apply"] + args, env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.expect_secret_patch("HA-ISSUED-CANARY-1")

    def test_expiring_token_is_renewed(self):
        args = self.start("state-converged.json")
        self.fake.state["tokens"][0]["expires_at"] = "2020-01-01T00:00:00+00:00"
        code, out, err = run(["--plan"] + args, self.env)
        self.assertEqual(code, ma.EXIT_DRIFT)
        self.assertIn("expire", out)
        code, out, err = run(["--apply"] + args, self.env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.expect_secret_patch("HA-ISSUED-CANARY-1")

    def test_missing_user_is_created_with_generated_password_then_token_issued(self):
        args = self.start("state-converged.json")
        self.fake.state["users"] = [u for u in self.fake.state["users"] if u["username"] != "svc-home-assistant"]
        self.fake.state["tokens"] = []
        code, out, err = run(["--plan"] + args, self.env)
        self.assertEqual(code, ma.EXIT_DRIFT, out + err)  # plus de blocage : mot de passe genere
        self.assertIn("+ user/svc-home-assistant create", out)
        self.assertIn("+ token/svc-home-assistant create", out)
        code, out, err = run(["--apply"] + args, self.env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        created = next(u for u in self.fake.state["users"] if u["username"] == "svc-home-assistant")
        self.assertEqual(created["role"], "service")
        self.assertEqual(self.fake.issued["HA-ISSUED-CANARY-1"], created["user_id"])
        (pw,) = self.fake.passwords
        self.assertGreaterEqual(len(pw), 16)  # MA exige 8 caracteres au moins
        self.expect_secret_patch("HA-ISSUED-CANARY-1")
        self.no_leak(out, err)
        # second passage : convergence, plus aucune ecriture
        self.env[HA_TOKEN_ENV] = "HA-ISSUED-CANARY-1"
        before = len(self.fake.writes())
        code, out, err = run(["--apply"] + args, self.env)
        self.assertEqual(code, ma.EXIT_OK, out + err)
        self.assertEqual(len(self.fake.writes()), before)
        self.assertEqual(len(self.kube.patches), 1)

    def test_kube_write_failure_is_error_without_leak(self):
        args = self.start("state-converged.json")
        self.kube.fail = True
        env = dict(self.env, APP_MA_HA_TOKEN="placeholder")
        code, out, err = run(["--apply"] + args, env)
        self.assertEqual(code, ma.EXIT_ERROR)
        self.assertIn("Secret", err)
        self.no_leak(out, err)
        self.assertNotIn(FakeKube.SA_TOKEN, out + err)

    def test_other_users_never_read_secrets(self):
        args = self.start("state-converged.json")
        env = dict(self.env, APP_MA_HA_TOKEN="placeholder")
        run(["--apply"] + args, env)
        self.assertTrue(all(not p[0].startswith("GET") for p in self.kube.patches))

    def test_desired_declares_token_and_generated_password(self):
        with open(os.path.join(APP, "desired.json"), encoding="utf-8") as f:
            d = json.load(f)
        u = next(u for u in d["users"] if u["username"] == "svc-home-assistant")
        self.assertEqual(u["role"], "service")
        self.assertTrue(u["password_generated"])
        self.assertNotIn("password_env", u)
        self.assertEqual(
            u["token"], {"name": "home-assistant", "secret_env": HA_TOKEN_ENV, "k8s_secret": HA_SECRET, "key": "token"}
        )


class TestDesired(unittest.TestCase):
    def test_desired_has_no_inline_secret_and_expected_values(self):
        with open(os.path.join(APP, "desired.json"), encoding="utf-8") as f:
            d = json.load(f)
        self.assertEqual(d["core"]["streams"], {"publish_ip": "10.0.20.192", "bind_port": 8097})
        sonos = next(p for p in d["providers"] if p["domain"] == "sonos")
        self.assertEqual(
            sonos["values"], {"manual_discovery_ip_addresses": ["10.0.35.50"]}
        )
        jf = next(p for p in d["providers"] if p["domain"] == "jellyfin")
        self.assertEqual(jf["values"]["password"], {"secret_env": "APP_MA_POLYFIN_PASSWORD"})
        self.assertEqual(d["prune_domains"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
