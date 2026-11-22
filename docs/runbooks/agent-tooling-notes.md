# Notes d'outillage pour les agents (pièges connus)

## kubectl-ro.sh : le verbe d'abord

`bash scripts/kubectl-ro.sh get pods -n media` est correct. `kubectl-ro.sh -n media get pods` est refusé (code 64) avec un message explicite : seul `--cluster <nom>` peut précéder le verbe.

## policy-check --tests et PyYAML

`tests/policies/gen-tests.py` importe PyYAML. `bash scripts/policy-check.sh --tests` (et `just policy-check`) crée tout seul un venv épinglé (`pyyaml==6.0.2`) dans `${POLICY_VENV:-${TMPDIR:-/tmp}/kube-ops-policy-venv}` quand le python système n'a pas PyYAML. Le binaire `kyverno` reste requis (`POLICY_CHECK=BLOCKED missing_tool=kyverno` sinon).

## Dérive de main et merge

- Ne pas tester « ma branche est à jour avec main » par `git merge-base --is-ancestor origin/main HEAD` strict : main avance toutes les minutes avec ~12 agents. Rebaser avant le push, puis laisser `gh pr merge --squash --delete-branch` trancher (GitHub refuse si le merge est vraiment impossible).
- Ne pas lancer `gh pr update-branch` sur une PR dont `mergeStateStatus` est `CLEAN` : cela crée un commit de merge, relance toute la CI et fait perdre des minutes sans rien corriger. Ne l'utiliser que si la PR est `BEHIND` ou `DIRTY`, et préférer `git rebase origin/main` puis push.

## app-test-changed.sh : digest dans un replacements

Un digest `@sha256:` placé dans un bloc `replacements:` de `kustomization.yaml` n'est suivi par aucun manager Renovate. `scripts/app-test-changed.sh` échoue (`replacements_digest`) pour toute app touchée dont la kustomization en contient un. Le digest va dans `images:` ou dans le manifeste.

## Où sont les ApplicationSets des previews

`k8s/bootstrap/argocd-root/`, pas `k8s/previews/` (qui ne contient que les guardrails). Voir `docs/runbooks/preview-environments.md`.
