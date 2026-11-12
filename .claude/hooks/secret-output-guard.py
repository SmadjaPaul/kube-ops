#!/usr/bin/env python3
"""PreToolUse guard (Bash): refuse commands whose output can carry secret values.

Wired in .claude/settings.json. Reads the hook JSON on stdin; exit 2 blocks the
call and the stderr message is returned to the model. Exit 0 lets it run.

Refused (see tests/agent-guard/secret-output-guard-test.sh):
- doppler secrets (list with values), secrets get|download|substitute|set|delete|upload;
  only `doppler secrets --only-names` passes. Use scripts/doppler-safe.sh.
- doppler run whose command dumps the environment (env, printenv, set, export -p,
  declare, compgen -v) or uses --command; doppler configure; --print-config,
  --debug, --no-verify-tls.
- kubectl get secret(s) with -o/--output/--template; kubectl exec ... env|printenv;
  kubectl config view --raw.
- bare env / printenv / set / export -p / declare -p|-x; ps showing environments.

Not a sandbox: an agent determined to obfuscate a command can get around it. It
stops the accidental, readable forms. Quoted text (commit messages, docs written
via heredoc, grep patterns) is ignored, except where a shell executes it
(bash -c, eval, $(...), backticks, heredocs fed to a shell).
"""

from __future__ import annotations

import json
import re
import sys

SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "source", "."}
EXEC_FLAG = re.compile(r"(?:\b(?:bash|sh|zsh|dash|ksh)\s+(?:-\w+\s+)*-\w*c|\beval|--command(?:=|\s))\s*$")


def _subst_parts(text: str) -> str:
    """Keep only $(...) and `...` parts of a double-quoted or heredoc body."""
    out, i = [], 0
    while i < len(text):
        if text.startswith("$(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append(" " + text[i + 2:j - 1] + " ;")
            i = j
        elif text[i] == "`":
            j = text.find("`", i + 1)
            j = len(text) if j < 0 else j
            out.append(" " + text[i + 1:j] + " ;")
            i = j + 1
        else:
            i += 1
    return "".join(out)


def executable_text(cmd: str) -> str:
    """Command text a shell would execute; plain quoted data is dropped."""
    out: list[str] = []
    i, n = 0, len(cmd)
    pending_heredocs: list[tuple[str, bool, bool]] = []  # (delimiter, quoted, fed_to_shell)
    while i < n:
        c = cmd[i]
        if c == "\n" and pending_heredocs:
            out.append(" ;\n")
            i += 1
            for delim, quoted, to_shell in pending_heredocs:
                body = []
                while i < n:
                    j = cmd.find("\n", i)
                    j = n if j < 0 else j
                    line = cmd[i:j]
                    i = j + 1
                    if line.strip() == delim:
                        break
                    body.append(line)
                text = "\n".join(body)
                if to_shell:
                    out.append(" ;\n" + text + " ;\n")
                elif not quoted:
                    out.append(_subst_parts(text))
            pending_heredocs = []
            continue
        if c == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            m = re.match(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", cmd[i:])
            if m:
                before = "".join(out)
                seg = re.split(r"[;&|\n]", before)[-1].split()
                to_shell = bool(seg) and seg[0].rsplit("/", 1)[-1] in SHELLS
                pending_heredocs.append((m.group(2), bool(m.group(1)), to_shell))
                out.append(" ")
                i += m.end()
                continue
        if c in "'\"":
            j = i + 1
            while j < n and cmd[j] != c:
                j += 2 if (c == '"' and cmd[j] == "\\") else 1
            body = cmd[i + 1:j]
            executes = bool(EXEC_FLAG.search("".join(out)))
            if executes:
                out.append(" " + body + " ")
            elif c == '"':
                out.append(" " + _subst_parts(body) + " ")
            else:
                out.append(" ")
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)



RULES: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\bdoppler\b.*\bsecrets\s+(get|download|substitute|set|delete|upload)\b"),
     "doppler secrets get/download/substitute/set/delete/upload imprime ou manipule des valeurs : "
     "utiliser scripts/doppler-safe.sh (names|has|set via stdin|delete)"),
    (re.compile(r"\bdoppler\b.*\bconfigure\b"), "doppler configure peut afficher le token Doppler"),
    (re.compile(r"\bdoppler\b.*(--print-config|--debug|--no-verify-tls)\b"),
     "doppler --print-config/--debug/--no-verify-tls interdit (token, TLS)"),
    (re.compile(r"\bdoppler\b.*\brun\b.*--command\b"),
     "doppler run --command : passer par scripts/doppler-safe.sh run -- <cmd>"),
    (re.compile(r"\bkubectl\b.*\bconfig\s+view\b.*--raw\b"), "kubectl config view --raw affiche les credentials"),
    (re.compile(r"\bkubectl\b.*\bexec\b.*\s--\s.*\b(env|printenv)\b"),
     "kubectl exec ... env/printenv affiche les variables du conteneur"),
]

ENV_DUMP = re.compile(
    r"^\s*(?:sudo\s+)?(?:printenv\b.*|env\s*(?:-0\s*)?|set\s*|export\s+-p\s*|declare\s+-[a-zA-Z]*[px][a-zA-Z]*\s*|compgen\s+-[ve]\s*)$"
)
PS_ENV = re.compile(r"^\s*ps\b.*(\s-[A-Za-z]*E|\se[A-Za-z]*(\s|$))")
SECRETS_LIST = re.compile(r"\bdoppler\b.*\bsecrets\b")
DOPPLER_RUN_DUMP = re.compile(
    r"\bdoppler\b.*\brun\b.*\s--\s+(?:\S*/)?(env|printenv|set|export|declare|compgen)\b(?!\s*[A-Za-z_]+=)"
)
KUBECTL_VERBOSE = re.compile(r"\bkubectl\b.*(\s--?v(=|\s+)?([6-9]|[1-9][0-9])\b|\s--vmodule\b)")
KUBECTL_SECRET_OUT = re.compile(r"\bkubectl\b.*\bget\b")
SECRET_WORD = re.compile(r"(^|[\s,/])(secret|secrets|sec)($|[\s,/.])", re.I)
OUTPUT_FLAG = re.compile(r"(^|\s)(-o(?!\s*=?\s*name\b)\S*|--output(?!\s*=?\s*name\b)\S*|--template\S*)")
NAMES_ONLY_PIPE = re.compile(r"^\s*(cut\s+-d\s*['\"]?=['\"]?\s*-f\s*1|sed\s+(-E\s+)?['\"]?s/=\.\*//['\"]?)\s*$")


def check(command: str) -> str | None:
    text = executable_text(command)
    for pattern, reason in RULES:
        if pattern.search(text.replace("\n", " ")):
            return reason
    whole = text.replace("\n", " ")
    if DOPPLER_RUN_DUMP.search(whole):
        return "doppler run -- env/printenv/set affiche les secrets injectés"
    # per segment checks
    raw_segments = [s for s in re.split(r"[;\n]|&&|\|\||\$\(|`|\(|\)", text)]
    for seg in raw_segments:
        pipes = seg.split("|")
        for k, part in enumerate(pipes):
            if ENV_DUMP.match(part):
                nxt = pipes[k + 1] if k + 1 < len(pipes) else ""
                if not NAMES_ONLY_PIPE.match(nxt):
                    return ("affichage de l'environnement (env/printenv/set/export -p/declare) : "
                            "lister les noms seulement, ex. `env | cut -d= -f1`")
            if PS_ENV.match(part):
                return "ps avec environnement des processus (e/-E) interdit"
            if SECRETS_LIST.search(part) and "--only-names" not in part:
                return ("doppler secrets sans --only-names affiche les valeurs : "
                        "`bash scripts/doppler-safe.sh names -p <projet> -c <config>`")
            if KUBECTL_VERBOSE.search(part):
                return "kubectl -v>=6 / --vmodule affiche les corps HTTP (données des Secrets comprises)"
            if KUBECTL_SECRET_OUT.search(part) and SECRET_WORD.search(part) and OUTPUT_FLAG.search(part):
                return ("kubectl get secret avec -o/--output affiche les données du Secret : "
                        "utiliser `describe secret` (tailles) ou `get secret` sans -o")
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    reason = check(command)
    if reason:
        print(f"secret-output-guard : commande refusée — {reason}. "
              "Règle : AGENTS.md (Safety) ; aucune valeur de secret dans une sortie d'outil.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
