# Optio : travail privé par Agentgateway (PLT-515)

Diagnostic et retour arrière. Exploitation générale : [optio.md](optio.md).
Ne jamais écrire, afficher ni committer une valeur de secret (clé, jeton, en-tête).

## Fonctionnement

- Travail dont le propriétaire est « moi » (travail privé de l'utilisateur Optio configuré,
  `OPTIO_GATEWAY_USER_ID` dans `k8s/applications/platform/optio/secret-sync.yaml`) : connexion par
  l'Agentgateway du cluster (`http://agentgateway.agentgateway.svc.cluster.local:4000`).
- Le CronJob `optio-secret-sync` (toutes les 15 min) écrit trois lignes privées (portée `user`)
  dans le magasin chiffré d'Optio :
  - `OPTIO_GATEWAY_URL` : URL de la passerelle ;
  - `OPTIO_GATEWAY_KEY` : clé virtuelle `optio` de la passerelle (Secret `optio-llm`) ;
  - `CLAUDE_AUTH_MODE` = `gateway` (écrite en dernier).
- Une connexion Optio privée exporte l'URL et la clé dans le pod d'agent.
- Travail dont le propriétaire est l'organisation : connexion de l'instance, inchangée.
- Alias de modèle de la passerelle (`k8s/applications/platform/agentgateway/resources.yaml`) :
  `text/strong` et `code/frontier`, choisis à chaque exécution, avec la fenêtre de contexte 200k.

**Comportement non documenté par Optio amont : à revérifier à chaque mise à jour d'Optio.**

## Tâches Pi : clé `optio-pi` (PLT-542)

- Clé virtuelle `optio-pi` (`k8s/applications/platform/agentgateway/optio-pi-key.yaml`), générée dans le
  cluster. Alias admis : `text/strong` seul. Budget : 5 000 000 tokens par 24 h, blocage au dépassement.
  `code/frontier` est refusé : un ticket `agent:opus` reste sur Claude Code.
- `optio-secret-sync` l'écrit dans la ligne privée `OPENAI_API_KEY` (le nom que le sélecteur de
  credential Pi d'Optio 0.26.4 accepte). Le journal du Job donne `credential=secret:<uuid>` : cet
  identifiant n'est pas un secret. C'est la valeur de `metadata.agentOptions.credential`, et son UUID est
  `OPTIO_PI_CREDENTIAL_ID` pour le dispatcher.
- Toute tâche Pi doit envoyer ce `credential`. Sans lui, Optio donne à Pi toutes les clés de fournisseur
  qu'il trouve.
- Ne pas lancer de tâche Codex ou OpenCode pour cet utilisateur : elle prendrait la même ligne
  `OPENAI_API_KEY` et l'enverrait à un hôte public.
- La connexion privée de la passerelle s'applique à tous les agents si son affectation n'a pas de filtre :
  la clé `optio` est alors aussi dans l'environnement du run Pi. Le lanceur Pi ne la transmet pas au
  harnais. **NON VÉRIFIÉ** : le filtre actuel de l'affectation.
- Retour arrière : revert du commit, puis suppression de la ligne privée `OPENAI_API_KEY` dans Optio
  (le revert seul la laisse en place).

## Vérification

1. Dernier Job : `bash scripts/kubectl-ro.sh logs -n optio job/<job>` doit montrer trois lignes
   `SYNC_STATUS=PASS <NOM> unchanged|written`. `SYNC_STATUS=FAIL` : lire le nom d'erreur, sans valeur.
2. Lancer une exécution privée puis lire les journaux de la passerelle (`just investigate agentgateway`).

## Symptômes

| Réponse de la passerelle | Cause | Action |
|---|---|---|
| `no API Key found` | Seul un en-tête `x-api-key` a été envoyé. | Vérifier que la connexion privée exporte la clé et que le pod l'envoie en jeton bearer. |
| `invalid credentials` | Un jeton bearer qui n'est pas la clé de la passerelle a été envoyé. | Vérifier que la ligne `OPTIO_GATEWAY_KEY` est à jour (prochain passage du CronJob) et que le pod n'envoie pas un autre identifiant. |

## Retour arrière

1. Revenir sur le commit qui a introduit les lignes privées (PR de branche `claude/`, `just check`,
   fusion, Argo).
2. Supprimer ensuite les trois lignes privées (`OPTIO_GATEWAY_URL`, `OPTIO_GATEWAY_KEY`,
   `CLAUDE_AUTH_MODE`) de l'utilisateur et désactiver la connexion privée.
   Le retour Git seul ne suffit pas : sans cette étape, les lignes et la connexion restent actives.
3. Vérifier qu'une exécution privée reprend la connexion de l'instance.
