# Optio : revue, correction et merge des PR kube-ops (PLT-515)

L'orchestrateur ([optio-intake.md](optio-intake.md), point 7) crée pour chaque PR d'une tâche privée :
une tâche de revue quand les checks sont verts, qui merge ou bloque ; une tâche de correction (3 au plus)
quand ils échouent. Ces tâches passent par la passerelle (`text/strong`). Un merge part en production par
Argo CD (risque accepté, MANDAT 30).

## Réglages du dépôt dans Optio

Revue, merge automatique et reprise automatique **désactivés**. Dans Optio 0.26.4, la surveillance des PR
écrit le nouvel état des checks avant que le moteur ne le compare à l'ancien : la revue `on_ci_pass` ne se
déclenche pas (constaté le 26/11 : PR mergées sans revue), alors que le merge automatique, lui, agit.

## Ce qui bloque un merge

- Les trois checks requis par le ruleset de `main` et l'état brouillon (GitHub les impose).
- La revue met en brouillon la PR qu'elle refuse. Les chemins réservés ne reposent que sur sa consigne :
  **aucun contrôle technique** (la revue des code owners de `docs/platform/kube-ops-main-ruleset.json` n'est pas
  appliquée).

Une PR mise en brouillon attend une personne. Une PR corrigée après un refus n'est pas relue automatiquement.

## Retour arrière

Désactiver le travail « Orchestrateur des tickets Linear ». Revenir sur un merge : revert de la PR.
