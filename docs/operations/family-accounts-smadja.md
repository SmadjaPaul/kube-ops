# Comptes Authentik de la famille Smadja (PLT-176)

Quatre comptes `internal` : Corinne, Philippe, Théo et Manon Smadja. Source : `k8s/infrastructure/auth/authentik/extra/blueprints/family-smadja.yaml`. Contrôle : `tests/harness/family-smadja-contract-test.sh`.

## Ce que le blueprint fait

- Il crée les comptes `corinne.smadja`, `philippe.smadja`, `theo.smadja`, `manon.smadja`, e-mail `prénom@smadja.dev`, chemin `users/internal/family`.
- `state: created` : il crée un compte absent et ne modifie jamais un compte existant. Il ne touche ni au mot de passe, ni au MFA, ni aux groupes ajoutés plus tard.
- Aucun mot de passe : Authentik pose un mot de passe inutilisable. Personne ne peut se connecter avant le lien de récupération.
- Groupe `smadja-family` : aucune application ne le lie. Le groupe existant `family` donne accès à 15 applications ; il n'est pas utilisé ici.
- Flux `family-recovery` : mot de passe (12 caractères minimum, zxcvbn ≥ 3), écriture, connexion. Pas d'étape d'identification ni d'e-mail : le flux démarre seulement depuis un lien créé par un admin. Il est lié à `smadja-family` : tout autre compte reçoit « flow not applicable ».
- La marque `authentik-default` reçoit `flow_recovery = family-recovery`. Le lien public « mot de passe oublié » ne change pas.

Ni adresse de récupération personnelle, ni secret, ni jeton dans Git. Les adresses personnelles restent dans Doppler pour Migadu seulement (`FAMILY_MAILBOX_RECOVERY_EMAILS`, homelab-infra `terraform/migadu-lechaplais`).

## Ordre

1. Boîtes `prénom@smadja.dev` créées en mode invitation Migadu (homelab-infra, PLT-293). Migadu envoie l'invitation à l'adresse personnelle.
2. Bascule MX de `smadja.dev` vers Migadu, décidée par Paul, puis test de réception.
3. Merge de ce blueprint : les comptes existent, sans accès et sans mot de passe. Ce merge peut précéder l'étape 2.
4. Après l'étape 2, Paul ouvre Authentik : Directory > Users > compte > « Send recovery link », étape `family-recovery-email`. Le lien arrive dans `prénom@smadja.dev` et reste valable 24 heures.
5. Avant l'étape 2 seulement, si Paul veut avancer : « Create recovery link », puis Paul envoie lui-même le lien à l'adresse personnelle. Aucun agent ne voit le lien.
6. Accès : Paul ajoute chaque compte au groupe `family` ou à un groupe par application. Le blueprint ne reprend pas ce choix.

## Vérification

- Statique : `bash tests/harness/family-smadja-contract-test.sh`.
- Runtime (après merge) : les 4 comptes existent, groupe `smadja-family`, aucune application dans leur bibliothèque, `GET /api/v3/flows/executor/family-recovery/` refusé en anonyme.
- Utilisateur : chaque personne définit son mot de passe et se connecte.
