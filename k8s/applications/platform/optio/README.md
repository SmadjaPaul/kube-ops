# Optio — routage du travail vers les fournisseurs de modèles

Namespace `optio`, chart `oci://ghcr.io/jonwiggins/optio` 0.26.4, Argo CD.
Ce document décrit par où passe chaque exécution d'Optio vers l'API de modèles.
Exploitation générale : `docs/operations/optio.md`.

## Deux chemins de connexion

| Propriétaire du travail | Connexion | Sortie du pod d'agent |
|---|---|---|
| Utilisateur Optio configuré (travail privé, propriétaire « moi ») | passerelle in-cluster | Agentgateway (Service `agentgateway`, port 4000) |
| Organisation | connexion d'instance | API Anthropic (jeton d'abonnement) |

## Travail privé : l'Agentgateway

1. Le CronJob `optio-secret-sync` (`secret-sync.yaml`, toutes les 15 min) écrit **trois lignes privées**
   (portée `user`, pour un seul utilisateur Optio) dans le magasin chiffré d'Optio :
   - `OPTIO_GATEWAY_URL` : URL de l'Agentgateway (`http://agentgateway.agentgateway.svc.cluster.local:4000`) ;
   - `OPTIO_GATEWAY_KEY` : clé virtuelle de l'Agentgateway (Secret `optio-llm`, aucune valeur dans Git) ;
   - `CLAUDE_AUTH_MODE` : `gateway`, écrit **en dernier** — l'URL et la clé existent donc avant qu'un
     travail cesse de recevoir la connexion d'instance.
2. Une **connexion Optio privée** exporte l'URL et la clé dans le pod d'agent : l'agent appelle
   l'Agentgateway. `CLAUDE_AUTH_MODE=gateway` est un mode qu'Optio ne gère pas, il n'injecte donc
   aucun identifiant Claude dans le pod.
3. Le travail de l'organisation garde la connexion d'instance : le pod d'agent utilise alors le jeton
   d'abonnement Claude, vers `api.anthropic.com` (liste FQDN sortante de `networkpolicy.yaml`).

## Alias de modèles de la passerelle

| Alias | Fournisseur | Usage |
|---|---|---|
| `text/strong` | MiniMax (format Anthropic Messages) | tickets mécaniques, repli du builder |
| `code/frontier` | API Claude (Anthropic) | revue de PR, tickets `model:frontier` |

L'alias est choisi **par exécution** ; chaque exécution tourne avec une fenêtre de contexte de **200k tokens**.
La clé `optio` de l'Agentgateway n'accepte que ces deux alias (budget 3 000 000 tokens / 24 h, `Block`).

## À re-vérifier à chaque montée de version

Ce routage repose sur un comportement qu'Optio amont ne documente pas : `CLAUDE_AUTH_MODE`, la portée
`user` du magasin de secrets, l'export de la connexion privée dans le pod d'agent et le module interne
`secret-service` de l'image épinglée. Le revérifier à chaque montée de version d'Optio, avant de
considérer le routage comme acquis.

## Secrets

Aucune valeur de secret dans ce dépôt : uniquement des noms (Secret `optio-llm`, clé `ANTHROPIC_API_KEY`).
