# Workflow-integrity — procédure d’admission des harness protégés

## État constaté

Le workflow `.github/workflows/workflow-integrity.yaml` compare les fichiers
du commit de base avec la tête de la PR. Tout changement sous
`tests/harness/*`, `.github/workflows/*`, `.github/actions/*`, `.justfile`,
`scripts/check-*.sh` ou le contrat V1 est refusé avec
`UNQUALIFIED_AUTOMATION_CHANGES`.

Le workflow ne contient actuellement aucune exception par label, commentaire,
approbation GitHub, auteur, branche ou fichier d’admission. Aucun CODEOWNER,
registre d’exception ou procédure d’autorisation versionnée n’a été trouvé dans
le dépôt. Une approbation de PR ordinaire ne transforme donc pas un échec en
admission, et il n’est pas légitime de relancer en boucle ou de contourner ce
contrôle.

Les échecs observés concernent uniquement les changements de harness requis par
PLT-56 :

- #947 — `tests/harness/longhorn-offsite-pvc-contract-test.sh`;
- #948 — `tests/harness/velero-storage-tier-test.sh`;
- #949 — `tests/harness/backup-audit-contract-test.sh` et assertions Atlantis.

## Procédure propriétaire requise

La voie autorisée actuellement est une évolution préalable du mécanisme de
workflow par le propriétaire du dépôt, dans une PR dédiée soumise aux règles de
protection GitHub. Cette PR doit introduire une admission explicite et
versionnée, puis être fusionnée avant de relancer les PR PLT-56.

La forme minimale recommandée est un registre d’admissions dans la branche de
base, vérifié par le workflow de base :

1. une entrée contient le dépôt, le numéro de PR, le SHA exact de la tête, la
   liste exacte des chemins autorisés, le motif, l’approbateur propriétaire et
   une date d’expiration courte;
2. le workflow lit uniquement le registre de la base, exige une correspondance
   exacte SHA + chemins + dépôt + PR, et produit un résultat distinct
   `WORKFLOW_INTEGRITY=ADMITTED` avec l’identifiant de l’admission;
3. les entrées expirées, les globes, les jokers, les labels et les commentaires
   sont refusés; aucune admission ne peut modifier le workflow lui-même dans la
   PR qu’elle autorise;
4. après fusion de chaque PR autorisée, l’entrée est retirée par une PR
   propriétaire séparée.

Cette procédure conserve le contrôle global : les changements non listés restent
en échec, les tests restent versionnés et exécutés, et la protection de branche
continue d’exiger les statuts et revues habituels. Elle ne doit pas être
implémentée comme une modification opportuniste dans #947, #948 ou #949.

## Action indispensable pour PLT-56

Le propriétaire du dépôt doit soit mettre en œuvre cette admission dédiée dans
une PR de contrôle, soit fournir une procédure équivalente déjà approuvée. Il
devra ensuite admettre séparément les trois SHAs actuels :

- #947 : `40dc36a3003403d488bd678de7400df702d12edc`;
- #948 : `b539a4ccac216e1b6762b25dd8e83d6717882afa`;
- #949 : `7accf1231312f098597ddbb8ef05e556a01f4eb0`.

Sans cette action propriétaire, les contrôles locaux restent informatifs et les
PR ne sont pas livrables, même lorsque les tests eux-mêmes passent.
