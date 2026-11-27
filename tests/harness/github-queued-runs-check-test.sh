#!/usr/bin/env bash
# PLT-555 : scripts/github-queued-runs-check.sh surveille les runs GitHub Actions
# qui restent en file (un runner ARC sature, un workflow bloque). Le script est
# consultatif : il n'arrete jamais la porte, il previent (WARN) quand un run
# attend depuis plus de QUEUED_MAX_MINUTES. Aucun test ne le couvrait : une
# `gh run list` cassee (API, jeton) ou un run bloque en file ne seraient vus par
# personne.
#
# Ce test rejoue le script avec un faux `gh` (fixture JSON locale) : aucun
# reseau, aucune ecriture dans le depot, aucun port fixe.
#
# Cas couverts : file vide (OK, aucun avertissement) ; un run ancien et un run
# recent (WARN, un seul run compte, le recent n'est pas compte) ; le seuil
# QUEUED_MAX_MINUTES est honore ; `gh` en erreur (WARN, code 0) ; `gh` qui
# renvoie du JSON invalide (WARN, code 0) ; `gh` absent (WARN, code 0) ; `jq`
# absent (WARN, code 0) ; la commande demandee a `gh` est celle attendue. Le
# script ne rend jamais un code different de 0.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/github-queued-runs-check.sh"
test_file="$repo_root/tests/harness/github-queued-runs-check-test.sh"
bash_list="$repo_root/scripts/check-bash-tests.list"

fail() {
  echo "GITHUB_QUEUED_RUNS_CHECK=FAIL $*" >&2
  exit 1
}

command -v jq >/dev/null || { echo "GITHUB_QUEUED_RUNS_CHECK=BLOCKED reason=jq_required"; exit 2; }

[[ -f "$script" ]] || fail "reason=missing_script path=$script"

# Le test doit tourner dans la porte locale canonique.
grep -qx 'tests/harness/github-queued-runs-check-test.sh' "$bash_list" ||
  fail "reason=not_listed file=scripts/check-bash-tests.list"

# Aucun appel reseau : le script parle a GitHub par `gh`, jamais par curl ou wget.
if grep -vE '^[[:space:]]*#' "$script" |
  grep -qE '(^|[^[:alnum:]_])(curl|wget|nc|ncat|ssh|scp)([^[:alnum:]_]|$)|https?://'; then
  fail "reason=network_call_detected"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/github-queued-runs-check-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# --- faux gh ----------------------------------------------------------------------
# Sert une fixture JSON locale et journalise les arguments recus.
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_LOG:-/dev/null}"
case "${FAKE_GH_MODE:-ok}" in
  error) echo "gh: HTTP 403 (jeton absent)" >&2; exit 1 ;;
  invalid) printf '%s\n' 'ceci nest pas du json' ;;
  *) cat "${FAKE_GH_FIXTURE:?FAKE_GH_FIXTURE manquant}" ;;
esac
SH
chmod +x "$tmp/bin/gh"

# --- PATH reduits (gh absent, jq absent) --------------------------------------------
# Chaque binaire est un lien symbolique vers le binaire reel de la machine : le
# PATH ne contient que ce qui est liste, rien d'autre (pas de gh de la machine).
mkdir -p "$tmp/nogh" "$tmp/nojq"
for cmd in bash date wc tr cat; do
  if path="$(command -v "$cmd" 2>/dev/null)"; then
    ln -sf "$path" "$tmp/nogh/$cmd"
    ln -sf "$path" "$tmp/nojq/$cmd"
  fi
done
if path="$(command -v jq 2>/dev/null)"; then ln -sf "$path" "$tmp/nogh/jq"; fi
ln -sf "$tmp/bin/gh" "$tmp/nojq/gh"

# --- helpers -----------------------------------------------------------------------
RUN_OUT=""
RUN_RC=0
run_check() { # <args...>
  RUN_RC=0
  RUN_OUT="$("$@" 2>&1)" || RUN_RC=$?
}

expect_rc() { # <attendu>
  [[ "$RUN_RC" -eq "$1" ]] || fail "reason=unexpected_rc want=$1 got=$RUN_RC out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ')"
}
expect_out() { [[ "$RUN_OUT" == *"$1"* ]] || fail "reason=missing_output want=$1 out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ')"; }
refute_out() { [[ "$RUN_OUT" != *"$1"* ]] || fail "reason=unexpected_output want_absent=$1 out=$(printf '%s' "$RUN_OUT" | tr '\n' ' ')"; }

# --- file vide : rien n'attend, aucun avertissement ---------------------------------
printf '%s\n' '[]' >"$tmp/empty.json"
run_check env "PATH=$tmp/bin:$PATH" FAKE_GH_FIXTURE="$tmp/empty.json" \
  FAKE_GH_LOG="$tmp/gh.log" bash "$script"
expect_rc 0
expect_out "OK: aucun run GitHub Actions en file depuis plus de 15 min"
refute_out "WARN"

# La commande demandee a `gh` est celle attendue (une liste des runs en file).
grep -qx 'run list --status queued --limit 100 --json databaseId,workflowName,createdAt' "$tmp/gh.log" ||
  fail "reason=unexpected_gh_call args=$(tr '\n' ' ' <"$tmp/gh.log")"

# --- un run ancien et un run recent -------------------------------------------------
old_at="$(jq -rn '(now - 1800) | todate')"
recent_at="$(jq -rn '(now - 120) | todate')"
jq -n --arg old "$old_at" --arg recent "$recent_at" '[{
  databaseId: 4242, workflowName: "V1 Contract", createdAt: $old
}, {
  databaseId: 4343, workflowName: "Runtime smoke", createdAt: $recent
}]' >"$tmp/mixed.json"

run_check env "PATH=$tmp/bin:$PATH" FAKE_GH_FIXTURE="$tmp/mixed.json" bash "$script"
expect_rc 0
expect_out "WARN: 1 run(s) GitHub Actions en file depuis plus de 15 min"
expect_out "4242"
expect_out "V1 Contract"
refute_out "4343"
refute_out "Runtime smoke"

# --- le seuil QUEUED_MAX_MINUTES est honore ------------------------------------------
# Le meme run attend depuis 30 min : au-dela de 60 min de seuil, ce n'est plus un
# avertissement.
run_check env "PATH=$tmp/bin:$PATH" QUEUED_MAX_MINUTES=60 FAKE_GH_FIXTURE="$tmp/mixed.json" bash "$script"
expect_rc 0
expect_out "OK: aucun run GitHub Actions en file depuis plus de 60 min"
refute_out "WARN"

# --- gh en erreur : un avertissement, jamais un echec ----------------------------------
run_check env "PATH=$tmp/bin:$PATH" FAKE_GH_MODE=error bash "$script"
expect_rc 0
expect_out "WARN: gh run list indisponible, queued-runs check skipped"

# --- gh qui renvoie du JSON invalide : un avertissement, jamais un echec ---------------
run_check env "PATH=$tmp/bin:$PATH" FAKE_GH_MODE=invalid bash "$script"
expect_rc 0
expect_out "WARN: gh run list indisponible, queued-runs check skipped"

# --- gh absent : un avertissement, jamais un echec -------------------------------------
run_check env "PATH=$tmp/nogh" bash "$script"
expect_rc 0
expect_out "WARN: gh absent, queued-runs check skipped"

# --- jq absent : un avertissement, jamais un echec -------------------------------------
run_check env "PATH=$tmp/nojq" bash "$script"
expect_rc 0
expect_out "WARN: jq absent, queued-runs check skipped"

if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$script" "$test_file" || fail "reason=shellcheck_failed"
fi

echo "GITHUB_QUEUED_RUNS_CHECK=PASS cases=7"
