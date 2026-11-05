# PLT-56 — registre de nettoyage en attente (2026-11-05)

Ce document prépare le périmètre d’une éventuelle PR de nettoyage. Il n’autorise aucune suppression et ne constitue pas un plan `kubectl delete`, Longhorn, S3 ou Velero.

## Objets conservés

- Le manifeste historique de synthèse contient 17 PVC et porte `executable=false` avec une liste de suppression vide : `docs/operations/dr-synth-historical-review-manifest-2026-10-19.json`.
- La capture live du 5 novembre montre 13 PVC `proxmox-csi`, 77 PV `Released`, 154 volumes Longhorn et 22 PVC classés comme résidus de restauration par le contrat d’audit strict.
- Les volumes Longhorn `listmonk/listmonk-uploads` et `twenty/twenty-storage` sont conservés même s’ils ne sont plus montés par un PVC actuel. Ils ne doivent pas être déduits de leur absence dans la matrice PVC.
- Les volumes et sauvegardes associés à Factory/Mastra, Immich Redis et aux restaurations de preuve restent conservés jusqu’à preuve de restauration applicative acceptée.

## Conditions préalables à toute suppression

Une suppression éventuelle devra être traitée dans une PR dédiée et réunir, pour chaque objet :

1. la correspondance UID/PV/volume et l’absence de montage ou de propriétaire actif;
2. une qualification de la donnée : reproductible, résidu de drill, doublon vérifié ou donnée importante;
3. une preuve de restauration récente pour le jeu de données important conservé par un autre mécanisme;
4. la validation explicite de l’inutilité de la copie distante concernée;
5. un plan de retour documenté et une revue opérateur avant toute mutation.

## Mesures à compléter après réconciliation

Répéter la fenêtre de l’audit I/O du 5 novembre après convergence Argo CD et comparer IOPS/débit disque, opérations Longhorn, octets réseau, occupation S3 fournisseur et températures CPU. Les tailles des CRD Longhorn ne sont pas une mesure d’occupation S3; la lecture `ListObjects` était refusée (`403 AccessDenied`) avec l’identité disponible.

## Décision PLT-56

L’état par défaut est `HOLD`. PLT-56 réduit la couverture déclarative via GitOps, mais ne supprime aucune donnée source, PVC historique, PV `Released`, backup Longhorn, backup Velero/Kopia ou objet S3.
