#!/usr/bin/env python3
"""PRD-84 : publie le jeton MA de svc-home-assistant dans Doppler (home/prd_maison).

Entrees (variables d'environnement, jamais d'argument) :
  APP_MA_HA_TOKEN                  jeton a publier (secretKeyRef, Secret natif ma-home-assistant-token)
  APP_MAISON_DOPPLER_WRITE_TOKEN   jeton de service Doppler en ecriture sur cette seule config
Idempotent : l'empreinte SHA-256 du jeton est rangee dans MA_HOME_ASSISTANT_TOKEN_SHA256 ;
le jeton n'est reecrit que si elle differe. Aucune valeur (jeton, empreinte, corps de reponse)
n'est affichee. Stdlib seule. Sortie : 0 = publie ou deja a jour, 1 = erreur ou refus.
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("DOPPLER_API_URL", "https://api.doppler.com")
PROJECT = "home"
CONFIG = "prd_maison"
KEY = "MA_HOME_ASSISTANT_TOKEN"
KEY_SHA = KEY + "_SHA256"
TIMEOUT = 20


class Refused(Exception):
    pass


def call(method, path, auth, query=None, body=None):
    """Retourne (statut, JSON ou None). Ne leve que sur panne reseau ; le corps n'est jamais journalise."""
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + auth)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, None


def stored_sha(auth):
    status, doc = call(
        "GET", "/v3/configs/config/secret", auth, {"project": PROJECT, "config": CONFIG, "name": KEY_SHA}
    )
    if status == 404:
        return None
    if status != 200 or not isinstance(doc, dict):
        raise Refused("lecture de l'empreinte refusee (HTTP %d)" % status)
    value = doc.get("value")
    return value.get("raw") if isinstance(value, dict) else None


def main():
    token = os.environ.get("APP_MA_HA_TOKEN", "").strip()
    auth = os.environ.get("APP_MAISON_DOPPLER_WRITE_TOKEN", "").strip()
    if not token:
        print("ERREUR: jeton svc-home-assistant absent (APP_MA_HA_TOKEN)", file=sys.stderr)
        return 1
    if not auth:
        print("ERREUR: jeton Doppler en ecriture absent (APP_MAISON_DOPPLER_WRITE_TOKEN)", file=sys.stderr)
        return 1
    digest = hashlib.sha256(token.encode()).hexdigest()
    try:
        if stored_sha(auth) == digest:
            print("OK: %s deja a jour dans %s/%s (aucune ecriture)" % (KEY, PROJECT, CONFIG))
            return 0
        status, _ = call(
            "POST",
            "/v3/configs/config/secrets",
            auth,
            body={"project": PROJECT, "config": CONFIG, "secrets": {KEY: token, KEY_SHA: digest}},
        )
        if status != 200:
            raise Refused("ecriture refusee (HTTP %d)" % status)
    except Refused as e:
        print("ERREUR: Doppler : %s" % e, file=sys.stderr)
        return 1
    except Exception as e:  # reseau, TLS, delai : seul le type est affiche
        print("ERREUR: Doppler injoignable (%s)" % type(e).__name__, file=sys.stderr)
        return 1
    print("OK: %s publie dans %s/%s" % (KEY, PROJECT, CONFIG))
    return 0


if __name__ == "__main__":
    sys.exit(main())
