# Runbooks des alertes locales (Prometheus)

Chaque règle locale hors CNPG, Authentik, NVMe, UPS et Django a un `runbook_url` qui pointe ici, sur son ancre. Format par alerte : **Signal** (ce que l'alerte mesure), **Première vérification** (commande en lecture seule via `scripts/kubectl-ro.sh`), **Action** (ce qui corrige la cause). Une alerte sans action possible doit être retirée ou passée en `info`.

Routage : `critical` va sur ntfy (téléphone). `warning` et `info` vont sur le receiver `null` : elles sont visibles dans Prometheus et Alertmanager, pas notifiées. `InfoInhibitor` ne notifie jamais.

### ArgoCDApplicationDegraded
- **Signal** : une Application Argo CD est `Degraded` depuis 5 min.
- **Première vérification** : `bash scripts/kubectl-ro.sh get applications -n argocd` puis `describe` de l'Application concernée.
- **Action** : corriger le manifeste dans Git (jamais de correction directe dans le cluster). Si la ressource est volontairement absente, documenter l'exception.

### ArgoCDApplicationOutOfSync
- **Signal** : désynchronisation entre Git et le cluster depuis 15 min.
- **Première vérification** : `get application <app> -n argocd -o jsonpath='{.status.sync}'` et le diff.
- **Action** : si Git est la référence, laisser Argo réconcilier ou merger le correctif. Si le runtime est la bonne version, la reporter dans Git.

### ArgoCDApplicationSyncFailed
- **Signal** : le dernier sync a échoué.
- **Première vérification** : `get application <app> -n argocd -o yaml` (champ `status.operationState.message`).
- **Action** : corriger l'erreur de manifeste ou de hook. Pour un sync bloqué, voir `scripts/argo-terminate-stuck-sync.sh`.

### ArgoCDOrphanedResourcesPresent
- **Signal** : des ressources existent dans un namespace géré par une Application sans les avoir dans Git.
- **Première vérification** : la liste des orphelins dans l'UI Argo ou `status.resources` de l'Application.
- **Action** : supprimer les orphelins après contrôle, ou les intégrer à Git. Voir `docs/operations/argo-orphan-cleanup.md`.

### ArgoCDOrphanedResourcesGrowing
- **Signal** : le nombre d'orphelins augmente.
- **Première vérification** : identique à ArgoCDOrphanedResourcesPresent.
- **Action** : traiter la cause de la croissance (souvent un chart qui change de nom de ressource) avant de nettoyer.

### AIOStreamsRouteProbeFailed
- **Signal** : la sonde blackbox de la route AIOStreams échoue depuis 10 min.
- **Première vérification** : `get pods -n media` pour AIOStreams, puis `get httproute` et les logs du pod.
- **Action** : redémarrer ou corriger la route si le pod est sain. Si le service est retiré, retirer la sonde.

### V1UserReadySyntheticProbeFailed
- **Signal** : la sonde synthétique du parcours utilisateur V1 échoue depuis 10 min.
- **Première vérification** : l'état de la route publique et du service cible (`get httproute`, `get endpointslice`).
- **Action** : rétablir le service cible. Ne pas désactiver la sonde pour faire passer l'alerte.

### DnsExactResolverDown
- **Signal** : le résolveur dns-exact-resolver n'est plus scrapé ou est indisponible depuis 5 min.
- **Première vérification** : `get pods -n dns-exact-resolver` et `events`.
- **Action** : corriger le pod (image, configuration) ; vérifier le ServiceMonitor si seules les métriques manquent.

### DnsExactResolverServfail
- **Signal** : plus de 5 % de réponses SERVFAIL pendant 10 min.
- **Première vérification** : logs du résolveur et résolution d'un nom de test.
- **Action** : vérifier l'amont DNS et la configuration des zones.

### DnsExactResolverHighLatency
- **Signal** : latence p95 au-dessus de 500 ms pendant 10 min.
- **Première vérification** : charge du pod (`top`) et état de l'amont.
- **Action** : augmenter les ressources si la charge est réelle ; sinon investiguer l'amont.

### EtcdWalFsyncSlow
- **Signal** : latence p99 de fsync du WAL etcd élevée pendant 10 min.
- **Première vérification** : `get --raw` sur `etcd_disk_wal_fsync_duration_seconds` et iowait de l'hôte.
- **Action** : traiter le disque du nœud de contrôle (PLT-417, PLT-463). Pas de réglage logiciel seul.

### EtcdDatabaseFragmented
- **Signal** : plus de 50 % de la base etcd est de l'espace libre.
- **Première vérification** : taille de la base par membre.
- **Action** : défragmenter pendant une fenêtre calme. Information seulement, pas d'urgence.

### ControlPlaneComponentRestarting
- **Signal** : un composant du plan de contrôle redémarre plus d'une fois par heure.
- **Première vérification** : `events` du namespace `kube-system` et `logs --previous` du pod.
- **Action** : traiter la cause (souvent PLT-417). Ne pas augmenter le délai de l'alerte.

### FactoryTempoDown
- **Signal** : le backend de traces Tempo est indisponible depuis 10 min.
- **Première vérification** : `get pods -n monitoring` pour Tempo, puis ses logs.
- **Action** : redémarrer ou restaurer Tempo ; les traces perdues ne se rattrapent pas.

### FactoryDBTJobFailed
- **Signal** : un run dbt de la plateforme Factory a échoué ; les marts peuvent être périmés.
- **Première vérification** : le Job en échec (`get jobs`, `logs`).
- **Action** : corriger le Job et le relancer. Frozen platform : ne pas ajouter de travail nouveau.

### ExternalSecretSyncFailingLong
- **Signal** : un ExternalSecret n'est pas synchronisé depuis plus d'1 h. Le Secret monté ne se met plus à jour.
- **Première vérification** : `describe externalsecret <name> -n <ns>` (champ `Message`). `SecretSyncedError` avec « could not get secret data » = clé absente dans Doppler `cluster/prd`.
- **Action** : rétablir la clé dans Doppler (`scripts/doppler-safe.sh has <KEY>`), puis forcer une resynchronisation. Ne jamais écrire la valeur dans Git ni dans le chat.

### VeleroScheduleNoSuccess
- **Signal** : un Schedule Velero a été tenté mais n'a jamais réussi depuis 6 h.
- **Première vérification** : `get backups -n velero` filtré sur le schedule, et les logs du pod Velero.
- **Action** : corriger la cause de l'échec (stockage R2, identifiants, PVC). Vérifier que le Schedule existe toujours dans Git.

### ArcRunnerListenerDown
- **Signal** : le listener ou le contrôleur ARC est hors service depuis 15 min. Les jobs CI ne sont plus pris.
- **Première vérification** : `get pods -n arc-systems` et `events`.
- **Action** : redémarrer le contrôleur ou corriger sa configuration dans Git.

### CloudflareTunnelDown
- **Signal** : aucun pod cloudflared Ready depuis 5 min. Les routes externes sont coupées.
- **Première vérification** : `get pods -n cloudflared` (ou le namespace du tunnel), `logs`.
- **Action** : corriger le déploiement. Garder l'accès d'administration par le LAN avant toute modification.

### CloudflareTunnelNoConnection
- **Signal** : `cloudflared_tunnel_ha_connections` vaut 0 depuis 5 min : le pod tourne mais le tunnel n'a plus de lien avec le bord Cloudflare.
- **Première vérification** : `logs -n cloudflared ds/cloudflared`, état du tunnel dans Cloudflare.
- **Action** : corriger le jeton ou le réseau sortant. Garder l'accès d'administration par le LAN.

### HostDiskWriteLatencyHigh
- **Signal** : latence d'écriture disque élevée pendant 15 min sur un hôte.
- **Première vérification** : métriques `node_disk_*` du périphérique, iowait.
- **Action** : traiter le disque (PLT-417, PLT-463). Ne pas redémarrer un nœud sans vérifier etcd.

### HostIowaitHigh
- **Signal** : iowait supérieur au seuil pendant 30 min.
- **Première vérification** : `top` sur le nœud, processus en I/O.
- **Action** : identifier le consommateur d'I/O ; le plus souvent une sauvegarde ou un scrub.

### KyvernoAdmissionNoReadyReplica
- **Signal** : aucun pod Kyverno admission Ready depuis 5 min. Les déploiements peuvent être bloqués.
- **Première vérification** : `get pods -n kyverno`, `events`.
- **Action** : rétablir les pods (voir PLT-417 pour la cause etcd). Ne jamais passer les webhooks en ignore pour faire taire l'alerte.

### KyvernoAdmissionReplicasDegraded
- **Signal** : moins de 2 réplicas admission Ready pendant 15 min.
- **Première vérification** : identique à KyvernoAdmissionNoReadyReplica.
- **Action** : corriger les pods défaillants ; la cible est 3 réplicas (PLT-400).

### KyvernoAdmissionPodRestarting
- **Signal** : un pod Kyverno redémarre plus de 3 fois par heure.
- **Première vérification** : `logs --previous` du pod.
- **Action** : traiter la cause (lease perdue, etcd lent). Vérifier les webhooks en fail-open.

### KyvernoWebhookCertExpiring
- **Signal** : le certificat TLS du webhook Kyverno (`kyverno-svc`) expire dans moins de 7 jours (sonde blackbox, PLT-470).
- **Première vérification** : `get pods -n kyverno` ; les contrôleurs Kyverno renouvellent ce certificat seuls : vérifier que le contrôleur d'admission tourne et que ses journaux ne montrent pas d'erreur de renouvellement.
- **Action** : rétablir le contrôleur ; ne jamais passer le webhook en ignore.

### KyvernoWebhookCertProbeFailed
- **Signal** : la sonde TLS de `kyverno-svc.kyverno.svc:443` échoue depuis 2 h.
- **Première vérification** : `get pods -n monitoring` (blackbox-exporter), NetworkPolicy egress de blackbox-exporter vers `kyverno:9443`, pods admission.
- **Action** : rétablir la sonde ; sans elle, l'expiration n'est plus surveillée.

### KyvernoWebhookFailOpen
- **Signal** : un webhook Kyverno est en fail-open : les politiques ne sont pas appliquées.
- **Première vérification** : `get validatingwebhookconfigurations` et l'état des pods admission.
- **Action** : rétablir les pods admission. Pendant la panne, aucune création de ressource n'est contrôlée : traiter en priorité.

### KyvernoWebhookLatencyHigh
- **Signal** : p99 du webhook Kyverno au-dessus de 2 s pendant 15 min ; chaque création de pod est ralentie.
- **Première vérification** : charge des pods admission et politiques coûteuses.
- **Action** : réduire les règles coûteuses ou augmenter les ressources.

### KyvernoPolicyRejectionsRising
- **Signal** : plus de 10 refus en 30 min.
- **Première vérification** : `events` et le rapport des politiques.
- **Action** : corriger les manifestes fautifs dans Git. Ne pas assouplir une politique sans décision écrite.

### KyvernoBackgroundControllerDown
- **Signal** : aucun pod background ou reports Kyverno Ready depuis 15 min.
- **Première vérification** : `get pods -n kyverno`.
- **Action** : rétablir le contrôleur. Impact : rapports et nettoyage à l'arrêt, pas de blocage des créations.

### VeleroBackupFailure
- **Signal** : une sauvegarde Velero a échoué.
- **Première vérification** : `get backups -n velero`, puis `describe backup <nom>`.
- **Action** : corriger la cause (R2, PVC, timeout). Relancer une sauvegarde manuelle après correction.

### VeleroBackupPartialFailure
- **Signal** : une sauvegarde Velero est partielle.
- **Première vérification** : `describe backup <nom>` (erreurs et avertissements par ressource).
- **Action** : identifier la ressource en erreur et la corriger. Une sauvegarde partielle n'est pas une sauvegarde complète.

### VeleroBackupNotRunRecently
- **Signal** : aucune sauvegarde Velero réussie depuis 48 h.
- **Première vérification** : `get schedules -n velero` et les dernières sauvegardes.
- **Action** : rétablir le planning. Vérifier la restauration selon `docs/operations/velero-auth-databases-restore-drill.md`.

### VeleroScheduleNeverSucceeded
- **Signal** : un Schedule Velero n'a jamais réussi depuis 30 min après sa création.
- **Première vérification** : `describe schedule <nom> -n velero`.
- **Action** : corriger la configuration du Schedule. Si le Schedule est obsolète, le retirer de Git.
