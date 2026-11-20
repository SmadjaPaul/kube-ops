#!/usr/bin/env bash
# Offline test of the agent-memory entry guard (PLT-368, D-2026-11-14-03):
#   scripts/agent-memory-entry-check.py must accept well-formed entries and refuse
#   any entry carrying a secret, without printing the suspicious value.
# No network, no Doppler, no Hindsight. Every secret-like fixture is assembled at
# run time from fragments, so this file contains no literal credential.
# Usage: bash tests/agent-guard/agent-memory-entry-test.sh
# shellcheck disable=SC2016 # literal text under test
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/scripts/agent-memory-entry-check.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-memory-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

GOOD_PIEGE='Type: piège
Composant: cnpg
Fait: La restauration Barman exige la meme version de PostgreSQL que la source. Le WAL seul ne suffit pas.
Source: PLT-303'

# Fake secret values, built from fragments at run time.
FAKE_AWS="AKIA""IOSFODNN7EXAMPLE"
FAKE_GH="ghp""_abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_SK="sk""-proj-abcdefghijklmnopqrstu1234"
FAKE_JWT="eyJ""hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP"
FAKE_BEARER="Bearer ""abcdef0123456789ABCDEF"
FAKE_ASSIGN="CF_ACCESS_CLIENT_SECRET=""s3cr3tvalue99"
FAKE_QUERY="https://example.invalid/mcp?access_token=""q1w2e3r4t5"
FAKE_MIXED="Zk8mQ2vL9pR4tW7xN1bH6yU3cF5dG0jS""A"

run_check() { # run_check TEXT -> writes OUT (stdout) and RC
  printf '%s\n' "$1" > "$WORK/entry.txt"
  OUT=$(python3 -I "$CHECK" "$WORK/entry.txt" 2>/dev/null)
  RC=$?
}

expect_ok() { # expect_ok NAME TEXT
  run_check "$2"
  if [ "$RC" = 0 ]; then ok "accepte : $1"; else ko "refuse a tort : $1 -> $OUT"; fi
}

expect_refused() { # expect_refused NAME TEXT RULE_SUBSTRING
  run_check "$2"
  if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q -- "$3"; then
    ok "refuse : $1"
  else
    ko "laisse passer ou mauvaise regle : $1 (rc=$RC) -> $OUT"
  fi
}

expect_no_leak() { # expect_no_leak NAME TEXT SECRET
  run_check "$2"
  if printf '%s' "$OUT" | grep -q -F -- "$3"; then ko "la sortie affiche la valeur : $1"; else ok "sortie sans valeur : $1"; fi
}

# --- 1. entrees valides
expect_ok "piege avec ticket" "$GOOD_PIEGE"
expect_ok "decision avec identifiant D-" "Type: décision
Composant: oke
Fait: Hindsight reste au homelab. OKE ne porte aucune donnee persistante.
Source: D-2026-11-18-01"
expect_ok "lecon avec URL de PR" "Type: leçon
Composant: argo
Fait: Un prune desactive protege les ressources avec etat.
Source: https://github.com/SmadjaPaul/kube-ops/pull/1549"
expect_ok "SHA Git de 40 hex toleree dans le Fait" "Type: leçon
Composant: r2
Fait: Le correctif de la recovery est au commit 0123456789abcdef0123456789abcdef01234567.
Source: PLT-303"
expect_ok "nom de variable seul (nom, pas valeur)" "Type: piège
Composant: tunnel
Fait: La cle CF_ACCESS_CLIENT_SECRET se lit dans Doppler infrastructure/prd.
Source: PLT-304"

# --- 2. format
expect_refused "format : une ligne de trop" "$GOOD_PIEGE
Extra: rien" "format"
expect_refused "format : ordre des champs" "Composant: cnpg
Type: piège
Fait: Une phrase.
Source: PLT-303" "format"
expect_refused "type inconnu" "Type: statut
Composant: cnpg
Fait: Une phrase.
Source: PLT-303" "type"
expect_refused "plus de 3 phrases" "Type: leçon
Composant: cnpg
Fait: Une. Deux. Trois. Quatre.
Source: PLT-303" "3 phrases"
expect_refused "source hors format" "Type: leçon
Composant: cnpg
Fait: Une phrase.
Source: un chat" "source"

# --- 3. secrets (le nom de regle doit apparaitre, la valeur jamais)
expect_refused "cle AWS" "Type: piège
Composant: r2
Fait: La cle $FAKE_AWS est dans le journal.
Source: PLT-303" "cle_aws"
expect_refused "jeton GitHub" "Type: piège
Composant: ci
Fait: Le jeton $FAKE_GH a ete colle.
Source: PLT-303" "jeton_github"
expect_refused "jeton de type sk-" "Type: piège
Composant: agent
Fait: La cle $FAKE_SK doit etre tournee.
Source: PLT-303" "jeton_sk"
expect_refused "JWT" "Type: piège
Composant: auth
Fait: Le jeton $FAKE_JWT remonte dans les logs.
Source: PLT-303" "jwt"
expect_refused "en-tete Bearer" "Type: piège
Composant: mcp
Fait: L'appel passait $FAKE_BEARER.
Source: PLT-305" "bearer"
expect_refused "affectation nom=valeur" "Type: piège
Composant: cloudflare
Fait: Le reglage $FAKE_ASSIGN a fuite.
Source: PLT-304" "affectation_secrete"
expect_refused "parametre de requete sensible" "Type: piège
Composant: mcp
Fait: Ne pas appeler $FAKE_QUERY dans un pointeur.
Source: PLT-305" "parametre_url_sensible"
expect_refused "chaine longue melangee" "Type: piège
Composant: mcp
Fait: Valeur fournie: $FAKE_MIXED.
Source: PLT-305" "chaine_longue"

# --- 4. aucune valeur ne fuit dans la sortie
expect_no_leak "AWS" "Type: piège
Composant: r2
Fait: $FAKE_AWS
Source: PLT-303" "$FAKE_AWS"
expect_no_leak "affectation" "Type: piège
Composant: cloudflare
Fait: $FAKE_ASSIGN
Source: PLT-304" "s3cr3tvalue99"

# --- 5. usage
printf 'x\n' > "$WORK/bad.txt"
python3 -I "$CHECK" "$WORK/missing.txt" >/dev/null 2>&1
[ $? = 2 ] && ok "fichier absent : code 2" || ko "fichier absent : code inattendu"

if [ "$FAIL" -eq 0 ]; then
  echo "agent-memory-entry-test: $PASS ok"
else
  echo "agent-memory-entry-test: $FAIL echec(s), $PASS ok"
  exit 1
fi
