# Transférer une ressource d'une Application Argo à une autre (SharedResourceWarning)

Symptôme : une Application affiche `SharedResourceWarning` (« X is part of applications A and B »). Deux Applications déclarent le même objet. Argo n'en désigne qu'un propriétaire à la fois (annotation `argocd.argoproj.io/tracking-id`) : l'autre se bat pour l'objet, ou le prune.

Règle : un objet a un seul propriétaire dans Git. Le transfert se fait en deux PR ou en une PR bien ordonnée, jamais en laissant les deux déclarations.

## 1. Diagnostiquer (lecture seule)

```bash
export PATH=/opt/homebrew/bin:$PATH
bash scripts/kubectl-ro.sh get applications -n argocd
bash scripts/kubectl-ro.sh describe application <app> -n argocd   # section Conditions
bash scripts/kubectl-ro.sh get <kind> <name> -n <ns> -o yaml      # annotation tracking-id = propriétaire actuel
```

Dans Git, chercher les deux déclarations (`grep -rn "name: <objet>" k8s/`). Décider du propriétaire cible : l'Application dont le cycle de vie couvre l'objet.

## 2. Procédure

1. PR 1 : retirer l'objet de la source de l'ancien propriétaire. Pour qu'Argo ne supprime pas l'objet au prune, mettre d'abord l'annotation `argocd.argoproj.io/sync-options: Prune=false` sur la ressource de l'ancienne source (ou retirer l'objet avec une sync sans prune). Un PVC, une base ou un secret racine : irréversible, donc `MANDAT requis`, PR laissée ouverte.
2. Merger, laisser l'ancien propriétaire se synchroniser. L'objet reste en place (`Prune=false`), sans propriétaire exclusif.
3. PR 2 (ou même PR si l'ordre est garanti par sync-wave) : ajouter l'objet à la source du nouveau propriétaire. Sa sync réécrit le `tracking-id` à son nom.
4. Vérifier : la condition `SharedResourceWarning` disparaît, les deux Applications sont `Synced`, l'objet n'a pas été recréé (même `uid`, même `creationTimestamp`).

```bash
bash scripts/kubectl-ro.sh get <kind> <name> -n <ns> -o jsonpath='{.metadata.uid}{" "}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
```

## 3. Geste console (agent navigateur) et limites

Si l'objet porte encore l'ancien `tracking-id` après la PR 2 (la sync n'a pas réécrit l'annotation), l'interface Argo permet de resynchroniser la ressource seule (Sync, option Replace décochée, Prune décoché). Prise du verrou : un seul agent navigateur à la fois (`mkdir .../locks/browser`, `rmdir` à la fin).

Limites :
- L'interface Argo est derrière Authentik : l'agent ne tape jamais de mot de passe ni de code 2FA ; si la session de Paul est expirée, c'est un blocage réel (ligne `paul_actions`).
- Ne jamais cliquer Delete avec cascade sur l'Application, ni Prune sur une ressource à données (PVC, Cluster CNPG).
- Pas d'écriture kubectl : `scripts/kubectl-ro.sh` est en lecture seule. Le correctif durable passe toujours par Git.
- Cette procédure n'a pas été rejouée sur un cas réel dans ce lot : consigner dans la PR tout écart constaté.
