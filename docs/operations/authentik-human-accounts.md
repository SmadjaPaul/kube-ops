# Comptes humains Authentik déclarés dans Git (PLT-176)

Les comptes humains déclarés dans Git sont dans `k8s/infrastructure/auth/authentik/extra/blueprints/groups.yaml`, à côté des groupes. Le mot de passe se définit par un lien admin : `flows-password-setup.yaml`. Contrôle : `tests/harness/authentik-human-users-contract-test.sh`.

## Règles

- `state: created` : le blueprint crée un compte absent et ne modifie jamais un compte existant (nom, e-mail, groupes, mot de passe, MFA). Les comptes créés au runtime (invitation) ne sont pas dans Git et ne sont pas touchés.
- Aucun mot de passe : Authentik pose un mot de passe inutilisable. Personne ne peut se connecter avant le lien.
- E-mail = la boîte `prénom@smadja.dev`. Les adresses de récupération personnelles ne vont jamais dans Git, une PR ou Linear : elles restent dans Doppler pour Migadu (`FAMILY_MAILBOX_RECOVERY_EMAILS`, homelab-infra `terraform/migadu-lechaplais`).
- L'accès passe par les groupes seulement (`family` aujourd'hui), jamais par une liaison par utilisateur. Aucun groupe superuser, aucun rôle depuis Git.

## Comptes déclarés

| Compte | Groupe |
|---|---|
| `corinne.smadja`, `philippe.smadja`, `theo.smadja`, `manon.smadja` | `family` |

## Lien de définition du mot de passe

- Flux `password-setup` : mot de passe (12 caractères minimum, zxcvbn ≥ 3), écriture, connexion. Pas d'étape d'identification ni d'e-mail : il démarre seulement depuis un lien créé par un admin.
- Politique `password-setup-internal-non-admin` : le compte cible doit être `internal` et non superuser. Un visiteur anonyme, un compte de service ou un compte de `authentik-admins` reçoit « flow not applicable ».
- La marque `authentik-default` reçoit `flow_recovery = password-setup`. Le lien public « mot de passe oublié » ne change pas.
- Étape e-mail `password-setup-email` pour « Send recovery link ». La durée du lien vient du champ « durée » de l'action admin, sinon de la valeur par défaut du tenant (authentik 2026.8 : 1 jour). L'étape e-mail ne la fixe pas.

## Ordre pour un nouveau compte

1. Boîte `prénom@smadja.dev` créée (homelab-infra, Migadu) et MX en place.
2. Merge de la PR qui ajoute le compte : il existe, sans mot de passe.
3. Paul : Directory > Users > compte > « Send recovery link », étape `password-setup-email`. Durée : 1 jour (laisser la valeur par défaut ou la saisir). Le lien arrive dans `prénom@smadja.dev`.
4. Avant le MX seulement : « Create recovery link », puis Paul envoie lui-même le lien. Aucun agent ne voit le lien.

## Vérification

- Statique : `bash tests/harness/authentik-human-users-contract-test.sh`.
- Runtime (après merge) : les comptes existent, groupe `family`, `GET /api/v3/flows/executor/password-setup/` refusé en anonyme.
- Utilisateur : chaque personne définit son mot de passe et se connecte.
