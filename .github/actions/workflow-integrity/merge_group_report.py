#!/usr/bin/env python3
"""Rapport workflow-integrity pour l'evenement merge_group (merge queue).

Execute UNIQUEMENT depuis le checkout de merge_group.base_sha (revision de base de la file, deja
sur main ou sur la file en cours). Le commit de la file (head_sha) n'est lu que comme donnees
inertes : `git diff --name-status`, jamais importe ni execute.

L'admission proprietaire (registre) est liee a UNE PR et a son empreinte ; elle est evaluee sur
l'evenement pull_request_target de chaque PR avant son entree dans la file. Ici on ne la re-evalue
pas : on liste les chemins proteges modifies par la file et on echoue si le diff est illisible
(fail-closed sur l'infrastructure). Mode rapport comme D-2026-11-14-02 : aucun blocage sur contenu.
"""
import argparse
import re
import subprocess
import sys

from verify import protected, safe_path

SHA = re.compile(r"^[0-9a-f]{40}$")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-sha", required=True)
    p.add_argument("--head-sha", required=True)
    args = p.parse_args()
    for label, value in (("base", args.base_sha), ("head", args.head_sha)):
        if not SHA.match(value):
            print(f"WORKFLOW_INTEGRITY=FAIL\nMERGE_GROUP_BAD_{label.upper()}_SHA", file=sys.stderr)
            return 1
    try:
        out = subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-only", "-z", args.base_sha, args.head_sha],
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as exc:
        print(f"WORKFLOW_INTEGRITY=FAIL\nMERGE_GROUP_DIFF_UNREADABLE={exc.stderr.decode(errors='replace').strip()}",
              file=sys.stderr)
        return 1
    paths = [x for x in out.decode("utf-8", errors="replace").split("\0") if x]
    unsafe = [x for x in paths if not safe_path(x)]
    hits = sorted(x for x in paths if x not in unsafe and protected(x))
    print("WORKFLOW_INTEGRITY_MERGE_GROUP=REPORT")
    print(f"MERGE_GROUP_CHANGED_PATHS={len(paths)}")
    print(f"MERGE_GROUP_PROTECTED_PATHS={','.join(hits) or '-'}")
    if unsafe:
        print(f"MERGE_GROUP_UNSAFE_PATHS={len(unsafe)}")
    print("ADMISSION=evaluee sur pull_request_target avant l'entree dans la file (non re-evaluee ici)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
