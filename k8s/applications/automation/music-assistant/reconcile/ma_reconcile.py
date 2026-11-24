#!/usr/bin/env python3
"""Reconciliateur Music Assistant (PRD-83), stdlib seule.

    ma_reconcile.py --plan  [--desired desired.json]   diff, aucune ecriture
    ma_reconcile.py --apply [--prune]                  applique, puis re-plan (doit etre vide)

Etat desire : JSON (stdlib, pas de PyYAML dans l'image). Les secrets y sont des references
{"secret_env": "NOM"} lues dans l'environnement ; ils ne sont jamais affiches (plan, erreurs).
MA ne relit pas ses secrets : un champ secret n'est envoye qu'a la creation d'un fournisseur.

Codes de sortie : 0 aucun ecart, 2 ecarts (plan) , 1 erreur, refus ou ecart residuel apres apply.

API : POST {ma_url}/api {"command": ..., "args": {...}}, Bearer APP_MA_RECONCILE_TOKEN.
Commandes verifiees dans le code de MA 2.10.8 (controllers/config/{core,providers,flows,players}.py,
controllers/webserver/auth.py) :
  config/core/get(domain), config/core/save(domain, values)
  config/providers(include_values=True) -> liste ; config/providers/get exige instance_id (sinon HTTP 500)
  config/providers/save(provider_domain, values, instance_id), config/providers/remove(instance_id)
  creation : config/providers/setup(provider_domain) -> etape de flux {flow_id, type, entries},
             puis config/flows/submit(flow_id, values) jusqu'a type "finish" (config/flows/get pour "progress")
  config/players(include_values=True), config/players/save(player_id, values)
  auth/users, auth/user/create(username, password, role), auth/user/update(user_id, role)
Un HTTP 500 de MA est generique ("Internal server error") : le detail est dans les journaux du serveur.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

EXIT_OK, EXIT_ERROR, EXIT_DRIFT = 0, 1, 2
TOKEN_ENV = "APP_MA_RECONCILE_TOKEN"
MAX_FLOW_STEPS = 10


class ReconcileError(Exception):
    pass


class Redactor:
    """Remplace toute valeur secrete connue par <secret> dans un texte."""

    def __init__(self):
        self.secrets = set()

    def add(self, value):
        if value:
            self.secrets.add(str(value))

    def __call__(self, text):
        out = str(text)
        for s in sorted(self.secrets, key=len, reverse=True):
            out = out.replace(s, "<secret>")
        return out


def is_secret(v):
    return isinstance(v, dict) and "secret_env" in v


class Client:
    def __init__(self, base_url, token, redact, timeout=30):
        self.url = base_url.rstrip("/") + "/api"
        self.token = token
        self.redact = redact
        self.timeout = timeout

    def call(self, command, **args):
        req = urllib.request.Request(
            self.url,
            data=json.dumps({"command": command, "args": args}).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + self.token,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            detail = ""
            if e.code != 500:  # le 500 de MA est toujours generique ; 400/403 portent la cause
                try:
                    detail = ": " + self.redact(e.read().decode("utf-8", "replace")[:200])
                except OSError:
                    pass
            raise ReconcileError(f"{command}: HTTP {e.code}{detail}") from None
        except (urllib.error.URLError, OSError) as e:
            raise ReconcileError(self.redact(f"{command}: {e}")) from None
        try:
            return json.loads(body) if body else None
        except ValueError:
            raise ReconcileError(f"{command}: reponse non JSON") from None


def entry_values(cfg):
    """values MA = {cle: {"value": v, ...}} ; accepte aussi {cle: v}."""
    out = {}
    for k, e in (cfg.get("values") or {}).items():
        out[k] = e["value"] if isinstance(e, dict) and "value" in e else e
    return out


def canon(key, v):
    """Les listes (ex. manual_discovery_ip_addresses) se comparent sans tenir compte de l'ordre."""
    if isinstance(v, list):
        return sorted(str(p) for p in v)
    return v


def load_desired(path, env):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    for k in ("ma_url", "providers"):
        if k not in d:
            raise ReconcileError(f"desired: cle '{k}' manquante")
    if not str(d["ma_url"]).startswith(("http://", "https://")):
        raise ReconcileError("desired: ma_url doit etre http(s)")
    seen = set()
    for p in d["providers"]:
        if p["domain"] in seen:
            raise ReconcileError(f"desired: fournisseur '{p['domain']}' declare deux fois")
        seen.add(p["domain"])
    return d


def resolve(values, env, redact):
    """Remplace {"secret_env"} par la valeur ; refuse si la variable manque."""
    out = {}
    for k, v in values.items():
        if is_secret(v):
            name = v["secret_env"]
            if not env.get(name):
                raise ReconcileError(f"secret '{name}' absent de l'environnement")
            redact.add(env[name])
            out[k] = {"secret": env[name], "ref": name}
        else:
            out[k] = v
    return out


def diff_values(desired, current):
    """-> [(cle, ancien, nouveau)] pour les cles non secretes qui different."""
    changes = []
    for k, want in desired.items():
        if isinstance(want, dict) and "secret" in want:
            continue
        have = current.get(k)
        if canon(k, have) != canon(k, want):
            changes.append((k, have, want))
    return changes


def build_plan(client, desired, env, redact, prune):
    plan = []

    for domain, wanted in (desired.get("core") or {}).items():
        cur = entry_values(client.call("config/core/get", domain=domain) or {})
        ch = diff_values(wanted, cur)
        plan.append(item("core", domain, "update" if ch else "noop", ch, domain=domain, values=wanted))

    providers = client.call("config/providers", include_values=True) or []
    by_domain = {}
    for cfg in providers:
        by_domain.setdefault(cfg.get("domain"), []).append(cfg)
    declared = set()
    for p in desired["providers"]:
        dom = p["domain"]
        declared.add(dom)
        vals = resolve(p.get("values") or {}, env, redact)
        found = by_domain.get(dom, [])
        if len(found) > 1:
            plan.append(item("provider", dom, "blocked", note="plusieurs instances, non supporte"))
        elif not found:
            keys = sorted(vals)
            plan.append(item("provider", dom, "create", [(k, None, "<secret>" if "secret" in vals[k] else vals[k]) for k in keys], domain=dom, values=vals))
        else:
            cur = found[0]
            ch = diff_values(vals, entry_values(cur))
            if cur.get("enabled") is False:
                ch.append(("enabled", False, True))
            plan.append(item("provider", dom, "update" if ch else "noop", ch, domain=dom, instance_id=cur.get("instance_id"), values={k: v for k, v in vals.items() if "secret" not in (v if isinstance(v, dict) else {})}, enable=cur.get("enabled") is False))
    for dom, found in by_domain.items():
        if dom in declared:
            continue
        for cfg in found:
            if prune and dom in (desired.get("prune_domains") or []):
                plan.append(item("provider", dom, "remove", instance_id=cfg.get("instance_id")))
            else:
                plan.append(item("provider", dom, "undeclared", note="non declare, conserve (prune non demande ou domaine hors prune_domains)"))

    if desired.get("players"):
        cur_players = {pl.get("player_id"): pl for pl in (client.call("config/players", include_values=True) or [])}
        for pl in desired["players"]:
            pid = pl["player_id"]
            if pid not in cur_players:
                plan.append(item("player", pid, "blocked", note="lecteur inconnu de MA (pas encore decouvert)"))
                continue
            ch = diff_values(pl.get("values") or {}, entry_values(cur_players[pid]))
            plan.append(item("player", pid, "update" if ch else "noop", ch, player_id=pid, values=pl.get("values") or {}))

    if desired.get("users"):
        users = {u.get("username"): u for u in (client.call("auth/users") or [])}
        for u in desired["users"]:
            name = u["username"]
            cur = users.get(name)
            if cur is None:
                pw = u.get("password_env")
                if not pw:
                    plan.append(item("user", name, "blocked", note="absent et sans password_env : a creer a la main (PRD-84)"))
                else:
                    if not env.get(pw):
                        raise ReconcileError(f"secret '{pw}' absent de l'environnement")
                    redact.add(env[pw])
                    plan.append(item("user", name, "create", [("role", None, u["role"])], username=name, role=u["role"], password=env[pw]))
                continue
            ch = [("role", cur.get("role"), u["role"])] if cur.get("role") != u["role"] else []
            plan.append(item("user", name, "update" if ch else "noop", ch, user_id=cur.get("user_id"), role=u["role"]))
    return plan


def item(kind, name, action, changes=None, note=None, **payload):
    return {"kind": kind, "name": name, "action": action, "changes": changes or [], "note": note, "payload": payload}


MARK = {"noop": "=", "update": "~", "create": "+", "remove": "-", "undeclared": "?", "blocked": "!"}


def render(plan, redact):
    lines = []
    for it in plan:
        lines.append(f"{MARK[it['action']]} {it['kind']}/{it['name']} {it['action']}" + (f" ({it['note']})" if it["note"] else ""))
        for k, old, new in it["changes"]:
            lines.append(redact(f"    {k}: {json.dumps(old)} -> {json.dumps(new)}"))
    return "\n".join(lines)


def pending(plan):
    return [i for i in plan if i["action"] in ("create", "update", "remove")]


def apply_item(client, it):
    p, kind, act = it["payload"], it["kind"], it["action"]
    if kind == "core":
        client.call("config/core/save", domain=p["domain"], values=p["values"])
    elif kind == "provider" and act == "create":
        values = {k: (v["secret"] if isinstance(v, dict) and "secret" in v else v) for k, v in p["values"].items()}
        res = client.call("config/providers/setup", provider_domain=p["domain"])
        submitted = set()
        for _ in range(MAX_FLOW_STEPS):
            step = res.get("type") if isinstance(res, dict) else None
            if step == "finish":
                # Un fournisseur sans flux (Sonos, Chromecast) est cree vide : les valeurs que
                # aucun formulaire n'a recues passent par config/providers/save.
                rest = {k: v for k, v in values.items() if k not in submitted}
                inst = (res.get("result") or {}).get("instance_id")
                if rest and inst:
                    client.call("config/providers/save", provider_domain=p["domain"], instance_id=inst, values=rest)
                return
            if step == "abort":
                raise ReconcileError(f"provider/{p['domain']}: flux abandonne ({res.get('reason')})")
            if res.get("errors"):
                raise ReconcileError(f"provider/{p['domain']}: formulaire refuse {sorted(res['errors'].items())}")
            if step == "form":
                keys = {e.get("key") for e in res.get("entries") or []}
                send = {k: v for k, v in values.items() if k in keys}
                submitted |= set(send)
                res = client.call("config/flows/submit", flow_id=res["flow_id"], values=send)
            elif step == "progress":
                time.sleep(1)
                res = client.call("config/flows/get", flow_id=res["flow_id"])
            else:
                raise ReconcileError(f"provider/{p['domain']}: etape de flux inattendue '{step}'")
        raise ReconcileError(f"provider/{p['domain']}: flux de configuration non termine")
    elif kind == "provider" and act == "update":
        values = dict(p["values"])
        if p.get("enable"):
            values["enabled"] = True
        client.call("config/providers/save", provider_domain=p["domain"], instance_id=p["instance_id"], values=values)
    elif kind == "provider" and act == "remove":
        client.call("config/providers/remove", instance_id=p["instance_id"])
    elif kind == "player":
        client.call("config/players/save", player_id=p["player_id"], values=p["values"])
    elif kind == "user" and act == "create":
        client.call("auth/user/create", username=p["username"], password=p["password"], role=p["role"])
    elif kind == "user":
        client.call("auth/user/update", user_id=p["user_id"], role=p["role"])


def main(argv=None, env=None):
    env = os.environ if env is None else env
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", action="store_true")
    ap.add_argument("--desired", default="/config/desired.json")
    ap.add_argument("--prune", action="store_true", help="supprime les fournisseurs non declares de prune_domains")
    ap.add_argument("--url", help="remplace ma_url (tests)")
    args = ap.parse_args(argv)
    if args.prune and not args.apply:
        print("refus: --prune n'a de sens qu'avec --apply", file=sys.stderr)
        return EXIT_ERROR
    redact = Redactor()
    try:
        token = env.get(TOKEN_ENV)
        if not token:
            raise ReconcileError(f"{TOKEN_ENV} absent : jeton MA a creer (PRD-84)")
        redact.add(token)
        desired = load_desired(args.desired, env)
        client = Client(args.url or desired["ma_url"], token, redact)
        plan = build_plan(client, desired, env, redact, args.prune)
        print(render(plan, redact))
        blocked = [i for i in plan if i["action"] == "blocked"]
        if args.plan:
            if blocked:
                return EXIT_ERROR
            return EXIT_DRIFT if pending(plan) else EXIT_OK
        if blocked:
            print("refus: elements bloques, rien n'est applique", file=sys.stderr)
            return EXIT_ERROR
        for it in pending(plan):
            apply_item(client, it)
            print(f"applique {it['kind']}/{it['name']} {it['action']}")
        again = build_plan(client, desired, env, redact, args.prune)
        if pending(again):
            print("ECART RESIDUEL apres apply :", file=sys.stderr)
            print(render(pending(again), redact), file=sys.stderr)
            return EXIT_ERROR
        print("apply termine, plan suivant vide")
        return EXIT_OK
    except ReconcileError as e:
        print(redact(f"erreur: {e}"), file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
