# Restauration du dump logique de factory-platform-pg2 (PLT-369)

Statut : runbook. Aucune restauration complète n'a encore été exécutée. La procédure ci-dessous
restaure dans une base temporaire, jamais dans `factory-platform-pg2` (la restauration en place
est une décision de Paul, destructive, hors de ce runbook).

## Ce qui existe

- Dump : chaque jour à 21:15 (Europe/Paris), `factory-platform-restic-backup` fait
  `pg_dump --format=custom` de la base entière `factory`, sous le rôle lecture seule
  `factory_source_ro`, directement dans restic (`--stdin-from-command`, pas de fichier disque).
  Un `pg_dump` en échec ne crée aucun snapshot.
- Dépôt restic : bucket `homelab-backup-restic`, préfixe `factory-platform/`. Host
  `factory-platform-restic`, tag `factory-platform-postgres`, nom du flux
  `factory-platform-postgres.dump`. L'endpoint R2 et les clés sont dans le Secret `restic-backup`
  (ExternalSecret Doppler). Aucune valeur n'est écrite dans Git ni dans ce runbook.
- Maintenance : dimanche 11:45, rétention, `restic check` et décodage du dump (`pg_restore --file=/dev/null`).
  Ce décodage ne prouve pas que la base se restaure : seule la section 3 le prouve.
- Limite de fraîcheur : la cible nominale est un dump par jour (RPO nominal d'environ 24 h), pas un
  maximum garanti. Le Job a `backoffLimit: 0` : un échec (panne de R2, de pg2 ou du nœud) n'est pas
  rejoué avant le lendemain, et une panne d'un jour laisse un snapshot plus ancien que 24 h. Le
  RPO réel est l'âge du dernier snapshot, à lire dans `restic snapshots` avant toute restauration.
  Pas d'archivage WAL vers R2 pour pg2 (PLT-94 lot 7).

## 1. Préparer l'accès (namespace de restauration uniquement)

Créer un namespace de restauration dédié, sans lien avec `factory-platform`. Y placer une copie du
Secret restic (ESO ou copie par un opérateur habilité). Ne jamais afficher les valeurs
(`kubectl get secret -o yaml` interdit dans le terminal partagé).

Avant de restaurer, relancer l'audit de couverture (lecture seule, depuis le poste d'un opérateur) et
vérifier que la sauvegarde de `factory-platform-pg2` y apparaît et que le dernier snapshot est récent :

```sh
just backup-audit
```

Vérifier l'accès au dépôt sans rien écrire :

```sh
restic snapshots --host factory-platform-restic --tag factory-platform-postgres
restic check --read-data-subset=5%
```

Noter l'identifiant du snapshot à restaurer (le plus récent par défaut).

## 2. Extraire le dump et contrôler le format

```sh
restic ls <snapshot-id> | grep factory-platform-postgres.dump   # chemin exact du flux
restic dump <snapshot-id> <chemin-exact-du-flux> > /scratch/factory.dump
pg_restore --list /scratch/factory.dump > /scratch/factory.toc   # erreur = dump inutilisable
```

Le TOC doit contenir au minimum les tables `public.raw_events`, `raw.events`, `control.*`
(par exemple `control.runs`), `public.github_collection_runs` et `public.github_collection_watermarks`.
L'absence de l'une d'elles est un échec de la sauvegarde.

## 3. Restaurer dans une base temporaire (preuve de restaurabilité)

Sur une instance PostgreSQL 17 jetable (même version majeure que le dump, pas d'archivage, pas de
sauvegarde, non exposée) :

Forcer l'hôte vers le serveur jetable avant toute commande, afin qu'aucune variable d'environnement
héritée (`PGHOST`, `PGSERVICE`, `PGPASSFILE`) ne pointe vers pg2 de production. Remplacer
`<hote-jetable>` par l'adresse du serveur jetable et contrôler le résultat avant de continuer :

```sh
unset PGSERVICE PGPASSFILE PGHOSTADDR
export PGHOST=<hote-jetable> PGPORT=5432
psql -Atc "select inet_server_addr(), current_setting('cluster_name', true)"   # doit désigner le serveur jetable
```

Si l'adresse affichée est celle de `factory-platform-pg2`, s'arrêter : ne rien restaurer.

```sh
createdb factory_restore
pg_restore --no-owner --no-privileges --exit-on-error -d factory_restore /scratch/factory.dump
```

`--no-owner` évite d'exiger les rôles `factory` et `factory_source_ro` ; `--no-privileges` ignore
les GRANT vers des rôles absents. Une erreur arrête la restauration : elle est consignée, le
snapshot est alors considéré comme non restaurable.

## 4. Comptes de contrôle

Sur la base temporaire :

```sql
SELECT count(*) FROM public.raw_events;
SELECT count(*) FROM raw.events;
SELECT count(*) FROM control.runs;
SELECT count(*) FROM public.github_collection_runs;
SELECT count(*) FROM public.github_collection_watermarks;
SELECT tgname FROM pg_trigger WHERE tgrelid = 'raw.events'::regclass AND NOT tgisinternal;
```

Limite : les comptes sont figés à l'heure du snapshot. Les comparer à la source (lecture seule,
même requêtes) donne un écart attendu égal aux lignes ingérées entre 21:15 et la lecture. Un
compte restauré supérieur à la source, ou un compte nul sur une table non vide, est un échec.
Le trigger append-only de `raw.events` doit exister (migration 0003). Le ledger `public.raw_events`
n'a pas de trigger équivalent (écart connu, à traiter séparément).

## 5. Vérifier les droits de lecture du dump (C1)

Le dump suppose que `factory_source_ro` peut lire toutes les couches. Le rôle reçoit
`pg_read_all_data` (`database-pg2.yaml`). Vérification à faire par un administrateur sur le cluster
live, en lecture seule :

```sql
SELECT has_table_privilege('factory_source_ro', 'public.raw_events', 'SELECT') AS raw_public,
       has_table_privilege('factory_source_ro', 'raw.events', 'SELECT') AS raw_schema,
       has_table_privilege('factory_source_ro', 'control.runs', 'SELECT') AS control;
```

Si l'une des valeurs est `false`, le dump est incomplet et non conforme. Le GRANT à documenter
(à appliquer seulement sur décision de Paul, jamais par ce runbook) :

```sql
GRANT USAGE ON SCHEMA public, raw, control TO factory_source_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public, raw, control TO factory_source_ro;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public, raw, control TO factory_source_ro;
```

Limite : `pg_read_all_data` ne contourne pas la RLS. Aucune politique RLS n'a été trouvée dans le
dépôt factory (HEAD 286d859), mais une future politique doit être reprise ici. Les grands objets
(large objects) ne sont pas couverts par ce rôle ; le dépôt factory n'en utilise pas.

## 6. Consigner la preuve

Date, identifiant du snapshot, taille du TOC, résultat de `pg_restore`, comptes de contrôle,
durée de restauration. Consigner dans les notes de reprise de la PR ou du ticket, sans valeur de secret.

## Ce que ce runbook ne prouve pas

- La restauration en place sur `factory-platform-pg2`.
- La sauvegarde Velero `velero-daily-factory-platform` (FS backup des PVC pg2, marquée
  `Velero-crash` dans `docs/operations/backup-coverage-static.md`) : les volumes données et WAL sont
  capturés séparément, donc non cohérents entre eux, et aucune restauration n'a été faite.
  Elle ne doit pas servir de preuve tant que cette section n'a pas été exécutée avec succès.
- Le couplage des identités restic et R2 avec paperless (décision de Paul, PR #1592, C3) : un
  mot de passe restic commun déchiffre les deux dépôts.
