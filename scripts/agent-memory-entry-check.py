#!/usr/bin/env python3
"""Garde-fou d'une entree de memoire agent (Hindsight, bank agents-homelab).

Usage : python3 -I scripts/agent-memory-entry-check.py [fichier]   (sans fichier : stdin)

Verifie, AVANT tout `retain` :
  1. format : exactement 4 lignes Type / Composant / Fait / Source, dans cet ordre ;
  2. Type dans {piège, leçon, décision} ; Fait au plus 3 phrases ;
  3. Source = decision D-AAAA-MM-JJ-NN, ticket PLT-n ou URL de PR GitHub ;
  4. aucun secret : cles privees, jetons connus (AWS, GitHub, OpenAI-like, JWT,
     Bearer), affectations `nom_secret=valeur`, parametres de requete sensibles,
     et longues chaines alphanumeriques melees (lettres + chiffres, 32 car. et plus).

Sortie : OK, ou REFUSE avec le nom des regles violees. La valeur suspecte n'est
JAMAIS affichee. Code retour 0 = accepte, 1 = refuse, 2 = usage.
Aucun reseau, aucune dependance hors bibliotheque standard.
"""
import re
import sys

TYPES = ("piège", "leçon", "décision")
LABELS = ("Type", "Composant", "Fait", "Source")

SOURCE_RE = re.compile(
    r"^(?:D-\d{4}-\d{2}-\d{2}-\d{2}|PLT-\d+|https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)$"
)

# Motifs de secrets connus. Chaque regle nomme le type, jamais la valeur.
SECRET_RULES = [
    ("cle_privee", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("cle_aws", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("jeton_github", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("jeton_sk", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{12,}")),
    (
        "affectation_secrete",
        re.compile(
            r"(?i)\b[\w-]*(?:secret|token|password|passwd|api[_-]?key|client[_-]?secret|credential)[\w-]*"
            r"\s*[:=]\s*[\"']?[^\s\"'$<>{}]{6,}"
        ),
    ),
    (
        "parametre_url_sensible",
        re.compile(r"(?i)[?&](?:token|key|secret|sig|signature|access_token|password)=[^\s&]{4,}"),
    ),
]

# Chaine longue, melangeant lettres et chiffres (cas non couvert par un motif nomme).
LONG_TOKEN_RE = re.compile(r"[A-Za-z0-9_+/-]{32,}")
COMMIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")  # SHA Git : toleree (Source, PR)
URL_RE = re.compile(r"https?://\S+")


def sentence_count(text: str) -> int:
    parts = [p for p in re.split(r"[.!?]+(?=\s|$)", text.strip()) if p.strip()]
    return len(parts)


def long_mixed_tokens(text: str):
    for token in LONG_TOKEN_RE.findall(text):
        if not (re.search(r"[A-Za-z]", token) and re.search(r"[0-9]", token)):
            continue
        if COMMIT_SHA_RE.match(token):
            continue
        yield token


def check(text: str) -> list[str]:
    errors: list[str] = []
    lines = [line for line in text.splitlines() if line.strip()]

    # 1. format
    if len(lines) != 4:
        errors.append("format: 4 lignes attendues (Type, Composant, Fait, Source)")
    fields = {}
    for index, label in enumerate(LABELS):
        if index >= len(lines):
            break
        prefix = f"{label}: "
        if not lines[index].startswith(prefix):
            errors.append(f"format: ligne {index + 1} doit commencer par « {label}: »")
            continue
        fields[label] = lines[index][len(prefix):].strip()

    # 2. Type et longueur du Fait
    if "Type" in fields and fields["Type"] not in TYPES:
        errors.append("type: valeur hors {piège, leçon, décision}")
    if "Fait" in fields:
        if not fields["Fait"]:
            errors.append("fait: vide")
        elif sentence_count(fields["Fait"]) > 3:
            errors.append("fait: plus de 3 phrases")

    # 3. Source
    if "Source" in fields and not SOURCE_RE.match(fields["Source"]):
        errors.append("source: attendu D-AAAA-MM-JJ-NN, PLT-n ou URL de PR GitHub")

    # 4. secrets (le texte entier, y compris les URL)
    for rule_name, pattern in SECRET_RULES:
        if pattern.search(text):
            errors.append(f"secret: règle {rule_name}")
    if any(True for _ in long_mixed_tokens(URL_RE.sub("", text))):
        errors.append("secret: règle chaine_longue_alphanumerique")
    return errors


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: agent-memory-entry-check.py [fichier]", file=sys.stderr)
        return 2
    if len(argv) == 2:
        try:
            with open(argv[1], encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            print("REFUSE: fichier illisible", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()

    errors = check(text)
    if errors:
        print("REFUSE")
        for error in errors:
            print(f"- {error}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
