# Backstage : GitHub App (remplace le PAT)

Statut : procédure de création pour Paul. Aucune App, aucun token ni secret n'est créé par l'agent.
Périmètre : la plateforme Backstage hébergée (svc-backstage, provisoire) lit le catalogue et publie
les PR de `platform-application` sur `SmadjaPaul/kube-ops`. Aujourd'hui elle utilise un PAT personnel
(`GITHUB_TOKEN`) : cette procédure le remplace.

## Permissions demandées (minimales)

| Permission | Niveau | Justification |
|---|---|---|
| `metadata` | read | obligatoire pour toute App |
| `contents` | write | le template pousse la branche `idp-app-<name>` (`k8s/apps-generated/<name>/`) et le catalogue lit `k8s/apps-generated/*/catalog-info.yaml` |
| `pull_requests` | write | ouverture de la PR draft par `publish:github:pull-request` |

Retirés : `actions: read` (aucun plugin Actions installé), `checks: read` (aucun plugin Checks),
`workflows` (le template n'écrit jamais dans `.github/workflows/`). Aucun webhook (`hook_attributes.active: false`).
`public: false` : l'App n'est installable que par le compte `SmadjaPaul`.

Limite connue : `contents: write` couvre tout le dépôt. La protection de `main` reste la seule barrière
contre une écriture directe ; le template ne pousse que sur une branche dédiée.

## Manifeste

Fichier de référence : [manifest JSON](#manifeste-json). Le helper HTML (manifest flow) est généré
localement par l'agent dans le scratchpad, il n'est pas versionné.

```json
{
  "name": "smadja-idp-backstage",
  "url": "https://github.com/SmadjaPaul/kube-ops",
  "description": "Backstage IDP (homelab) : lecture catalogue et PR de platform-application",
  "public": false,
  "redirect_url": "http://localhost:8765/github-app-created",
  "callback_urls": ["https://backstage.smadja.dev/api/auth/github/handler/frame"],
  "setup_on_update": false,
  "hook_attributes": { "active": false },
  "default_events": [],
  "default_permissions": {
    "metadata": "read",
    "contents": "write",
    "pull_requests": "write"
  }
}
```

`redirect_url` est local : la page n'existe pas, le code de conversion reste dans l'URL de la barre
d'adresse (usage unique, 1 heure). Ne pas le coller dans le dépôt ni dans un chat.

## Procédure (clics)

1. Ouvrir le helper local `scratchpad/idp/backstage-github-app-manifest.html` dans le navigateur.
   Il envoie le manifeste à `https://github.com/settings/apps/new` (compte `SmadjaPaul`).
2. Sur la page GitHub, vérifier le nom `smadja-idp-backstage` et les permissions, puis **Create GitHub App**.
3. Sur la page de l'App, noter l'**App ID** (nombre).
4. Section **Client secrets** : **Generate a new client secret**, copier la valeur (affichée une fois).
5. Section **Private keys** : **Generate a private key**, un fichier `.pem` est téléchargé.
   Le stocker dans Doppler puis le supprimer du disque.
6. Menu **Install App** : installer sur `SmadjaPaul`, choisir **Only select repositories**, sélectionner
   `kube-ops`, **Install**. Ne rien choisir d'autre.
7. Le *Client ID* (`Iv1.…`) est affiché sur la page de l'App.

L'installation id n'est pas nécessaire : Backstage la résout lui-même par propriétaire
(`allowedInstallationOwners: [SmadjaPaul]`).

## Clés Doppler

Projet et config : ceux du token `doppler-access-token` (namespace `external-secrets`), lus par le
ClusterSecretStore `doppler-cluster`. Noms alignés sur la convention du dépôt (`ATLANTIS_APPS_GH_APP_ID`) :

| Clé Doppler | Valeur | Champ Backstage |
|---|---|---|
| `BACKSTAGE_GH_APP_ID` | App ID (nombre) | `appId` |
| `BACKSTAGE_GH_APP_CLIENT_ID` | Client ID (`Iv1.…`) | `clientId` |
| `BACKSTAGE_GH_APP_CLIENT_SECRET` | client secret | `clientSecret` (requis par le schéma) |
| `BACKSTAGE_GH_APP_KEY_PEM` | contenu complet du `.pem` (multiligne) | `privateKey` |

Les tokens agents (`BACKSTAGE_AGENT_A_TOKEN`, `BACKSTAGE_AGENT_B_TOKEN`) sont à fournir par Paul dans le
même projet. Ils ne sont pas créés par l'agent.

## Configuration Backstage

Déjà présente dans `images/backstage/app-config.yaml` :

```yaml
integrations:
  github:
    - host: github.com
      apps:
        - appId: ${BACKSTAGE_GH_APP_ID}
          clientId: ${BACKSTAGE_GH_APP_CLIENT_ID}
          clientSecret: ${BACKSTAGE_GH_APP_CLIENT_SECRET}
          privateKey: ${BACKSTAGE_GH_APP_KEY_PEM}
          allowedInstallationOwners:
            - SmadjaPaul
```

Aucun `token` (PAT) n'est défini.

## Vérification hors réseau

`images/backstage/scripts/check-config.cjs` valide la configuration contre les schémas des plugins et
vérifie que `appId` est un nombre, qu'aucun PAT n'est présent et que `catalog.readonly` est actif.
Il n'appelle aucun service distant.

Résultats observés (2026-11-17, clé RSA éphémère et appId factice) :

- configuration complète : `schema: ok`, `appId: number`, `github_token_pat: false`.
- `appId` non numérique : échec propre `Unable to convert config value ... to a number`.
- un appel `getCredentials` avec identifiants factices (un seul appel) : rejet propre
  `HttpError: Integration not found`, le process ne plante pas.

Ce qui n'est pas vérifié ici : l'authentification réelle (il faut l'App créée). À valider après
installation par `backstage` : lecture de `k8s/apps-generated/*/catalog-info.yaml` puis création de PR.

## Manifeste JSON

Voir le bloc ci-dessus. Le champ `callback_urls` est requis par le formulaire GitHub mais inutilisé
(aucun fournisseur GitHub humain n'est configuré : cf. docs/platform/backstage-hosting.md).
