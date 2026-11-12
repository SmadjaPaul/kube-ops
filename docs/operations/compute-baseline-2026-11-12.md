# Baseline compute du WTR Max — 12 novembre 2026 (PLT-211)

Mesure en lecture seule via l'API Prometheus du namespace `monitoring`. Aucune
mutation, aucun profiling, aucun test de charge. Niveau de preuve : mesure
RUNTIME (Prometheus), sans reconstruction GitOps. Fenêtre principale : 24 h se
terminant le 2026-11-12 vers 12:00 UTC. Fenêtre secondaire : 7 jours (rétention
Prometheus d'environ 10 jours). Chiffres arrondis.

## Limites de la mesure

- L'hôte Proxmox et la VM Talos ont redémarré 6 fois en 7 jours
  (`changes(node_boot_time_seconds[7d])`) ; l'uptime actuel est d'environ 33 h.
  Les moyennes 7 jours mélangent donc plusieurs démarrages à froid.
- Cet audit a lui-même chargé Prometheus (requêtes 7 jours, deux timeouts).
  Les dernières heures de lecture du volume Prometheus ne sont pas
  « au repos ».
- Absents de Prometheus : SMART/usure NVMe (TBW), RPM des ventilateurs, CPU par
  processus QEMU, métrique par VM Proxmox. L'API Proxmox n'a pas été
  interrogée. Le CPU « hôte » ci-dessous vient du node-exporter de l'hôte
  (job `proxmox-host`).
- `container_fs_reads_bytes_total` de Prometheus et de l'instance-manager ne
  correspond pas à la charge disque physique (voir « Artefacts »).

## Ce qui était déjà prouvé (PLT-56, PLT-187, PLT-168, PLT-208)

- Tctl a atteint 100,1 °C la nuit du 10 au 11 ; CPU dbt et ARC nuls à certains
  pics : la chaleur n'est pas expliquée par une seule charge.
- CNPG `factory-platform-postgresql` : CrashLoop (checkpoint de réplication
  corrompu), retries dbt ; CronJob dbt suspendu (#1195), restauration isolée
  validée sur le plan structurel seulement.
- ARC (état du 11–12/11 dans PLT-56) : image Factory préconstruite, scale set
  `factory-ci-arc-light`, correctif GHCR #1200 en attente d'un credential ; cache
  mise (homelab-infra) à constater sur de vrais runs ; Cilium stabilisé après
  #1245 (timeouts FQDN 162 → 3).
- Audit backup : 29/42 PVC protégés, dernière sauvegarde CNPG complète
  ancienne ; périmètre Longhorn non modifié.
- Règles `kube-apiserver-burnrate` désactivées par #1256 (dernier échantillon
  du groupe : 2026-11-12 11:06 UTC) ; PLT-208 prévoit une réactivation bornée.
- Longhorn instance-manager : 2,46 → 0,3 cœur (PLT-187, #1255) ; la série 7 jours
  confirme la baisse le 7/11 mais montre un retour à 2,3 cœurs le 11/11 de 19 h
  à 03 h UTC (voir ci-dessous).

## Thermique, puissance, fréquence (hôte)

| Mesure | Valeur | Requête |
|---|---|---|
| Tctl actuel | 87–88,5 °C | `node_hwmon_temp_celsius{job="proxmox-host",chip="pci0000:00_0000:00:18_3",sensor="temp1"}` |
| Tctl moyenne 7 j / 24 h | 88,0 / 89,6 °C | `avg_over_time(…[7d])`, `[1d]` |
| Tctl p95 / max 7 j | 99,9 / 100,4 °C | `quantile_over_time(0.95,…[7d])`, `max_over_time` |
| Part du temps au-dessus de 85 / 90 / 95 °C (7 j) | 63 % / 33 % / 11 % | `avg_over_time((… > bool 95)[7d:5m])` |
| Puissance socket (hwmon `power1`) moyenne 7 j | 39,7 W (min 31, p95 45, max 49) | `avg_over_time(node_hwmon_power_average_watt[7d])` |
| Fréquence moyenne | 4,28 GHz (7 j), gouverneur `performance` | `avg(node_cpu_scaling_frequency_hertz)` |
| Refroidissement noyau | état `Processor` = 0 (pas de throttling noyau visible) | `node_cooling_device_cur_state{type="Processor"}` |
| Températures NVMe / DIMM | NVMe 47,9 °C (max 7 j 67,9), DIMM 49–53 °C | `node_hwmon_temp_celsius` |

Le p95 à 99,9 °C avec une moyenne de 88 °C indique des plateaux proches de la
limite, pas seulement des pics. Les pics de 7 jours coïncident avec les
fenêtres 17–20 h le 10/11 et 20 h–02 h le 11/11–12/11 (hôte 8 à 8,6 cœurs).

## CPU : hôte, VM, modes

| Mesure (moyenne 24 h sauf mention) | Valeur |
|---|---|
| Hôte, occupation (16 threads) | 5,42 cœurs (7 j : 5,26 ; p95 8,4 ; max 15,1) |
| Hôte, temps invité (QEMU) | 4,49 cœurs |
| Hôte, user / system / iowait / steal | 4,44 / 0,64 / 0,09 / 0 |
| VM Talos, occupation (12 vCPU) | 4,56 cœurs (7 j : 4,40 ; p95 7,3 ; max 11,6) |
| VM, user / system / irq / softirq / iowait / steal | 2,23 / 1,40 / 0,22 / 0,21 / 0,19 / 0,06 |
| VM, contexte-switchs / interruptions | 114 k/s / 69 k/s |
| Somme des conteneurs (`image!=""`) | 3,00 cœurs |
| Pression PSI VM : CPU / IO / mémoire (part du temps en attente) | 18 % / 3,2 % / 0,5 % |

Écart Talos / Proxmox : l'hôte voit 5,42 cœurs, la VM 4,56, le temps invité est
de 4,49. Il reste environ 0,9 cœur côté hôte (system 0,64 + iowait 0,09 +
reste), attribuable à QEMU, aux entrées-sorties ZFS et à l'hôte lui-même ; la
mesure ne permet pas de le répartir (pas de CPU par processus). Ne pas
additionner les deux lignes : l'hôte contient déjà la VM.
Écart interne à la VM : 4,56 − 3,00 ≈ 1,5 cœur n'est attribué à aucun pod
(noyau, kubelet, containerd, softirq/irq).

## Mémoire

- VM : 47 GiB, disponible 16 GiB (min 14,4 GiB sur 7 j), cache 11,5 GiB, anonyme
  26,5 GiB, pas de swap, PSI mémoire 0,5 %. Pas de pression.
- Hôte : 60,7 GiB, disponible 8,1 GiB, ARC ZFS 5,4 GiB sur 6,1 GiB max.
- Plus gros working sets : kube-apiserver 3,67 GiB, instance-manager 3,09 GiB,
  hindsight-api 1,50, Prometheus 0,90, argocd-application-controller 0,85,
  immich-server 0,77, stirling-pdf 0,77, gpt-researcher 0,71, authentik-server
  0,68, paperless 0,66.

## Disque

| Mesure (24 h) | Valeur | Requête |
|---|---|---|
| NVMe hôte, écritures physiques | 21,6 MB/s (≈ 1,86 To/j) ; 7 j : 14,5 MB/s (≈ 1,26 To/j) ; p95 74 ; max 5 min 99,6 | `sum(rate(node_disk_written_bytes_total{job="proxmox-host",device="nvme0n1"}[24h]))` |
| NVMe, lectures | 0,66 MB/s | idem `read` |
| NVMe, IOPS écriture / flush | 294 / 39 par s ; taille moyenne 72 KiB | `node_disk_writes_completed_total`, `node_disk_flush_requests_total` |
| HDD sda / sdb | 0,37 MB/s chacun | idem `device=~"sda\|sdb"` |
| VM, disque système (`sda`) écritures / lectures | 10,9 / 9,1 MB/s | `node_disk_written_bytes_total{job="node-exporter",device="sda"}` |
| ZFS `vm-101-disk-0` écritures logiques | 10,9 MB/s | `node_zfs_zpool_dataset_nwritten{dataset="nvme/vm-disks/vm-101-disk-0"}` |
| ZIL (sans SLOG) | 11,0 MB/s, 47 commits/s | `node_zfs_zil_zil_itx_metaslab_normal_bytes` |
| Longhorn, écritures frontales (tous volumes) | 0,92 MB/s | `sum(avg_over_time(longhorn_volume_write_throughput[24h]))` |

Amplification apparente : 10,9 MB/s logiques pour 21,6 MB/s physiques, soit
×2,0. Le ZIL reçoit autant d'octets que la VM écrit (11,0 MB/s `needcopy`,
`indirect` à 0). Le mécanisme « chaque écriture est écrite deux fois (ZIL puis
groupe de transactions) » est l'explication la plus cohérente, mais reste une
HYPOTHÈSE : ces trois taux agrégés n'attribuent pas les écritures physiques à
la VM et au ZIL (autres écritures de l'hôte, comportement ZFS). Une mesure par
dataset/zvol avant et après changement le confirmera.

Origine des 10,9 MB/s de la VM, par `container_fs_writes_bytes_total` (somme
pods : 6,9 MB/s) :

| Source | Écritures 24 h |
|---|---|
| Runners ARC (191 pods en 24 h) | 4,5 MB/s ≈ 391 Go/j (médiane 2,6 Go par pod, jusqu'à 4,5 Go) |
| Longhorn instance-manager | 1,07 MB/s |
| Polyfin (app) | 0,25 MB/s (volume `polyfin-data` : 0,40 MB/s, pic 219 MB/s) |
| kube-apiserver | 0,15 MB/s |
| Loki / Prometheus | 0,08 / 0,07 MB/s |
| Bases CNPG (WAL) | 0,05–0,10 MB/s chacune |
| Non attribué (≈ 4 MB/s) | hypothèse : téléchargements d'images containerd, journaux nœud, etcd |

À 391 Go/j, les runners représentent environ 41 % des écritures de la VM ; avec
l'amplification ZFS, environ 780 Go/j physiques (≈ 42 % du NVMe).

Endurance : l'usure SMART n'est pas dans Prometheus. À 1,26–1,86 To/j,
confirmer l'indice « pourcentage utilisé » et le TBW du SSD (CT1000P310SSD8)
avant toute conclusion.

## Réseau

| Mesure (24 h) | Valeur |
|---|---|
| VM, carte physique | 2,4 MB/s reçus, 1,2 MB/s émis |
| Retransmissions TCP / erreurs / drops | 0,02 % / 0 / ≈ 0 |
| instance-manager Longhorn (interface pod) | 135 MB/s émis en moyenne, 437 MB/s en rafale (trafic local iSCSI/volume, pas la carte) |
| DNS | 30,7 req/s, 76 % NXDOMAIN, 0 SERVFAIL/REFUSED |
| Cilium, drops | 4,9/s « VLAN traffic disallowed », 2,6/s « Policy denied » |
| Hubble | 703 flux/s |
| Régénérations d'endpoints Cilium | 1,26/s |

## Rafales instance-manager : ce qui est confirmé

Sur 30 heures (instance-manager, pas de 3 h) : 0,3 cœur de base, rafale à
1,98–2,24 cœurs de 11/11 20 h à 12/11 02 h UTC, retour à 0,3 dès 05 h UTC. Sur 7
jours : bursts à 2,2–2,5 cœurs les 5 et 6/11, 1,5 le 10/11 à 15 h, 2,3 le 11/11.

Séries alignées sur la fenêtre 11/11 19 h – 12/11 03 h UTC :

- lectures du volume Prometheus (`sdbs`) : 213 à 435 MB/s ;
- émission réseau de l'instance-manager : 350 à 437 MB/s ;
- CPU Prometheus : 0,20 à 0,33 cœur (base 0,05) ;
- durée du groupe de règles `kube-apiserver-burnrate.rules` : 60 à 157 s
  (intervalle 30 s), maximum 242 s sur 24 h, 143 itérations manquées en 24 h ;
- temps moyen d'évaluation des règles sur 24 h : 0,35 s/s, contre 0,012 s/s
  sur la dernière heure après #1256.

Le groupe burnrate a disparu à 11:06 UTC. CONFIRMÉ : l'alignement temporel et
le mécanisme (une règle qui relit des semaines de TSDB, que Longhorn sert à
l'instance-manager). NON ENCORE PROUVÉ : que la suppression supprime les
rafales. La rafale s'est arrêtée à 03 h UTC, avant le déploiement, et la
dernière heure est polluée par cet audit. Il faut 24 à 48 h sans rafale
instance-manager après #1256 avant de conclure.

## Contrôleurs

| Contrôleur | Mesure 24 h | Constat |
|---|---|---|
| kube-apiserver | CPU 0,34 (p95 0,59, max 0,91) ; 46 req/s ; 1 412 watchers | `leases` PUT 9,7/s, `selfsubjectaccessreviews` POST 4,6/s, `clusters` GET 3,5/s, `backupvolumes` PUT 1,1/s ; pas de label client exposé |
| Argo CD application-controller | CPU 0,16 (p95 0,66, max 1,08), 0,85 GiB ; 0,34 réconciliation/s | 32 apps ; syncs 24 h : `apps-platform` 438, `infra-monitoring` 66, `infra-network` 64, `infra-controllers` 49 |
| Argo CD repo-server | CPU 0,03 (max 0,38) | 3 à 4 restarts par ReplicaSet sur 7 j |
| Cilium | agent 0,30 (p95 0,76 sur un pod) | 3 pods d'agent différents en 24 h (rollouts ou recréations, non investigué) |
| Longhorn manager | CPU 0,19 (p95 0,25), 326 MiB | file de travail : 37,6 ajouts/s `backup`, 30,2/s `snapshot` ; 1 142 CR Backup, 174 volumes (75 attachés, 99 détachés) |
| CNPG operator | 0,004 | négligeable |
| ARC controller + listeners | < 0,001 chacun | négligeable ; le coût est dans les runners |
| Observabilité | Prometheus 0,131, Alloy 0,024, Loki 0,009, reste < 0,01 ; RAM ≈ 1,9 GiB | voir PLT-212 pour la cardinalité |
| Falco | 0,081 | permanent |
| Trivy operator | 0,012 | ponctuel |
| Tempo | CPU 0,002, 52 MiB, 0,025 span/s | quasi inutilisé ; coût marginal |

Prometheus : 177 k séries actives (plage 150–221 k sur 7 j), 4,3 k échantillons/s,
7,6 Go de blocs (rétention taille 15 Go), 17 compactions/24 h, 26 cibles `up`.

## Anomalies qualifiées

- Pods : 155 Running, 67 Succeeded (45 `velero`, normal), 30 Failed, 9 Pending.
  Les 39 « non Running » = 30 Failed + 9 Pending, tous résiduels :
  - Failed : 18 dans `factory-platform` (dbt et collector, CronJobs suspendus
    depuis ; pods en erreur conservés), 6 dans le drill `invoice-ninja…-v2`
    (CronJob de sauvegarde logique encore actif à 04:15), 6 dans `dr-protect-*`
    (5) et `openclaw-restore-drill-…-v4` (1).
  - Pending : 8 dans `invoice-ninja-restore-drill-20261009`, 1 dans `-v2`.
  Aucun n'est un incident de production.
- PVC : 91 Bound, 10 Pending. Les 10 sont dans les drills de restauration
  (`openclaw-restore-drill-20261005` ×4, `…-v2` ×1, `…-v3` ×1, soit 6 ;
  `invoice-ninja-restore-drill-20261009` ×4 ; ceux d'OpenClaw sont sur
  `longhorn-fast` avec volume référencé mais capacité 0) : reliquats, pas de
  service impacté.
- Restarts 7 j : 2 696 au total. `factory-platform-postgresql-1` 1 358 (53 sur
  24 h, aucun depuis 19 h ; le cluster reste « cannot proceed to
  reconciliation due to an error while interacting with plugins »),
  `openclaw-operator` ≈ 1 100 sur 7 pods successifs (un pod actuel : 267
  restarts en 32 h ; erreur : cache `OpenClawInstance` jamais synchronisé,
  CRD présent), `matrix-mas-postgresql-1` 103 (aucun sur 24 h).
- Argo : 2 apps OutOfSync. `apps-platform` (health Unknown) : ressource
  `Cluster factory-platform-postgresql` OutOfSync, 34 orphelins, boucle de sync
  automatique (438 syncs/24 h). `infra-controllers` : sync en échec
  (« namespace kube-system may not be deleted », tentative de prune), Secret
  `argocd-secret` OutOfSync, 178 orphelins (objets Velero `Backup`) ; 49
  syncs/24 h.
- Cibles de scrape tombées : `kube-controller-manager`, `kube-scheduler`
  (métriques non exposées) et `alloy` (`up == 0`).
- `dbt` et `github-collector` : CronJobs suspendus (voulu), dernier planning il
  y a 19–22 h ; ne plus consommer de CPU.

## Top 20 des consommateurs (fenêtre 24 h)

Légende confiance : H haute (mesure directe et mécanisme prouvé), M moyenne,
B basse (hypothèse).

| # | Consommateur | Ressource | Contribution | Régime | Cause probable | Conf. | Optimisation possible |
|---|---|---|---|---|---|---|---|
| 1 | Longhorn instance-manager | CPU, réseau local | 0,92 cœur (22 CPU-h/j), p95 2,48, base 0,3 ; 3,1 GiB | rafales ≈ 8 h/j + base | relecture du TSDB Prometheus par le groupe burnrate | H (alignement), causalité à confirmer | #1256 (fait), PLT-208 règles bornées |
| 2 | Noyau et services hors pods (VM) | CPU | ≈ 1,5 cœur (system 1,40, irq+softirq 0,43) | permanent | iSCSI/volumes, réseau, kubelet/containerd/Talos | B | profiler après baisse de la charge ; réduire #1, #3 |
| 3 | Runners ARC | I/O disque | 391 Go/j ; 4,5 MB/s ; CPU 0,11 (2,6 CPU-h/j) | ponctuel (191 pods) | `_work`, outils et caches réinstallés dans chaque pod | M-H | emptyDir en mémoire ou cache partagé, caches mise/pip/npm |
| 4 | ZFS sur l'hôte | I/O disque NVMe | 21,6 MB/s physiques pour 10,9 logiques (×2) | permanent | écritures synchrones : ZIL puis txg, sans SLOG | M (corrélation, mécanisme à confirmer) | `logbias=throughput` sur le zvol ou SLOG ; à tester |
| 5 | kube-apiserver | CPU, RAM | 0,34 cœur (p95 0,59) ; 3,67 GiB | permanent | 46 req/s, 9,7 PUT lease/s, 4,6 SSAR/s, 1 412 watchers | M | identifier les clients, espacer les leases |
| 6 | Cilium (agents) | CPU | 0,30 cœur (p95 0,76) | permanent | 1,26 régénérations d'endpoint/s, 703 flux Hubble/s | M | réduire Hubble, ajuster les politiques FQDN |
| 7 | Argo CD controller | CPU | 0,16 cœur (max 1,08) ; 0,85 GiB | permanent + pics | boucles de sync de 2 apps OutOfSync | M-H | corriger les écarts, `ignoreDifferences`, retry |
| 8 | Surcoût hôte Proxmox | CPU | ≈ 0,9 cœur (system 0,64) | permanent | QEMU, E/S ZFS, hôte | B | tester après #4 |
| 9 | Prometheus | CPU, RAM, I/O | 0,13 cœur ; 0,9 GiB ; règles 0,35 s/s (0,012 depuis #1256) | permanent | 177 k séries, 4,3 k éch./s, règles lourdes | H | PLT-208, PLT-212 |
| 10 | longhorn-manager | CPU, API | 0,19 cœur ; 326 MiB | permanent | 37,6 + 30,2 ajouts/s en file backup et snapshot, 1 142 Backup | M | élaguer les Backup, intervalle de poll |
| 11 | Falco | CPU | 0,081 cœur | permanent | analyse syscalls | M | règles/ressources à revoir |
| 12 | Authentik (ns auth) | CPU, RAM | 0,107 cœur ; 1,15 GiB | permanent | worker, serveur, PostgreSQL | M | mesure plus fine, probablement légitime |
| 13 | LibreChat MongoDB | CPU, I/O | 0,060 cœur ; 0,9 IOPS écriture | permanent | base de l'assistant | B | à observer |
| 14 | Polyfin (données) | I/O | 0,25–0,40 MB/s ; pics 219 MB/s | ponctuel | écritures du volume de données | M | cause des pics à qualifier |
| 15 | factory-platform (CNPG, dbt, collector) | CPU, restarts | dbt 0,37–0,48 cœur par job il y a 22 h ; 1 358 restarts/7 j | passé (suspendu) | checkpoint corrompu et retries | H | PLT-168 ; nettoyer les pods en erreur |
| 16 | openclaw-operator | restarts | ≈ 8 restarts/h, CPU ≈ 0 | permanent (bruit) | cache `OpenClawInstance` jamais synchronisé | M | corriger ou suspendre |
| 17 | Loki + Alloy | CPU, RAM, I/O | 0,033 cœur ; 0,5 GiB ; 29 KB/s, 61 lignes/s ; 0,09 MB/s écrits | permanent | collecte logs | H | peu de gain : PLT-212 |
| 18 | Invoice Ninja (drill + prod) | CPU, RAM | 0,037 + 0,022 cœur ; 1,1 + 0,43 GiB | permanent | drill de restauration encore en place avec CronJob actif | H | retirer le drill |
| 19 | RAM applicative | RAM | hindsight-api 1,5 GiB ; immich 0,77 ; stirling-pdf 0,77 ; gpt-researcher 0,71 ; paperless 0,66 | permanent | applications | H | right-sizing, scale-to-zero des outils peu utilisés |
| 20 | Réseau/DNS | réseau, CPU | 2,4 + 1,2 MB/s carte ; DNS 30,7/s dont 76 % NXDOMAIN ; 4,9 drops VLAN/s | permanent | `ndots`, trafic VLAN filtré | B | ndots/cache DNS, filtre VLAN |

Hors top 20 mais mesuré : Tempo (0,002 cœur, quasi sans trace), ARC controller,
CNPG operator, Velero node-agent (0,005), Trivy (0,012).

## Causes confirmées et hypothèses

CONFIRMÉ :

1. Rafales CPU instance-manager (≈ 2,3 cœurs, 8 h) alignées sur des lectures
   Prometheus à 200–435 MB/s et sur des évaluations burnrate de 60–242 s.
2. Les écritures NVMe valent environ le double des écritures de la VM : le ZIL
   reçoit 11,0 MB/s pour 10,9 MB/s logiques, sans SLOG.
3. Les runners ARC écrivent 391 Go/j (4,5 MB/s), soit environ 41 % des
   écritures de la VM.
4. Les 39 pods « non Running » et les 10 PVC Pending sont des reliquats de
   drills et de jobs suspendus, sans impact de service.
5. Boucles de sync Argo sur deux apps OutOfSync (438 et 49 syncs/24 h).

HYPOTHÈSES (non prouvées) :

- Le noyau de la VM (≈ 1,5 cœur non attribué) est dominé par le stockage et le
  réseau local.
- Passer à `logbias=throughput` ou à un SLOG réduirait fortement les écritures
  physiques sans perte de durabilité inacceptable.
- Le gouverneur `performance` à 4,3 GHz moyen contribue au plafonnement
  thermique ; un plafond de boost ou un gouverneur différent pourrait réduire
  Tctl pour un coût de latence limité.
- Les écritures non attribuées (≈ 4 MB/s) viennent de containerd, des journaux
  et d'etcd.
- L'usure du SSD est critique à 1,3–1,9 To/j : à vérifier par SMART.

## Artefacts de mesure

- `container_fs_reads_bytes_total` du conteneur Prometheus (142 MB/s sur 24 h)
  et de l'instance-manager (135 MB/s) est supérieur aux lectures de `sda`
  (9,1 MB/s) : ces compteurs ne mesurent pas la même couche (lecture logique,
  caches) que le disque physique. Un surcomptage n'est pas établi ; ne pas les
  lire comme charge disque physique, utiliser `node_disk_*` du volume
  (`sdbs` : 14,6 MB/s en moyenne 1 h).
- `longhorn_volume_read_throughput` du volume Prometheus (168 MB/s moyen) est
  dans le même cas ; `longhorn_volume_write_throughput` est cohérent (0,92
  MB/s au total).
- `node_hwmon_power_*` mesure le socket (capteur du GPU intégré), pas la prise.

## Plan d'optimisation priorisé

| # | Action (une PR) | Bénéfice estimé | Risque | Coût |
|---|---|---|---|---|
| 1 | Valider #1256 sur 24–48 h puis PLT-208 : règles burnrate bornées | ≈ −0,6 cœur (instance-manager) − 0,1 (Prometheus) | faible | S |
| 2 | ARC : `_work` et outils en emptyDir mémoire ou cache partagé, caches mise/pip/npm | −3 à −4 MB/s VM (≈ −6 à −8 MB/s NVMe) | faible-moyen | M |
| 3 | Hôte : `logbias=throughput` (ou SLOG) sur le zvol de la VM, via homelab-infra | NVMe −30 à −45 % (hypothèse) | moyen (durabilité, réversible) | M |
| 4 | Argo : corriger `Cluster factory-platform-postgresql` et les écarts de `infra-controllers` (prune de `kube-system`, `argocd-secret`) pour stopper les boucles | −0,1 à −0,2 cœur, −apiserver | faible | S |
| 5 | Retirer les drills (`restore-drill`, `dr-protect`, CronJob 04:15) et les pods en erreur factory ; sans toucher aux PVC portant des données | 10 PVC Pending, 39 pods, 1 CronJob quotidien en moins | faible-moyen (règle PVC) | S |
| 6 | Corriger ou suspendre `openclaw-operator` (CrashLoop) | −8 restarts/h, alertes propres | faible | S |
| 7 | Longhorn : réduire les boucles backup/snapshot (poll, élagage des 1 142 Backup) sans changer la couverture | ≈ −0,1 cœur, −1 req/s apiserver | moyen | M |
| 8 | Tester gouverneur/boost plafonné (hôte) | Tctl −3 à −8 °C (hypothèse) | faible, réversible | S |
| 9 | Identifier les clients apiserver (leases 9,7/s, SSAR 4,6/s, `clusters` 3,5/s) | ≤ −0,15 cœur | faible | S |
| 10 | Cilium/DNS : Hubble allégé, `ndots`, filtre VLAN | ≈ −0,1 cœur | faible | S |

Chaque optimisation suit : mesure avant, changement minimal réversible, CI,
merge, réconciliation Argo (`just status-app`), mesure après dans des
conditions comparables.

## Requêtes de référence

```
# Tctl, p95, part de temps > 95 °C
node_hwmon_temp_celsius{job="proxmox-host",chip="pci0000:00_0000:00:18_3",sensor="temp1"}
quantile_over_time(0.95, node_hwmon_temp_celsius{job="proxmox-host",chip="pci0000:00_0000:00:18_3",sensor="temp1"}[7d])
avg_over_time((node_hwmon_temp_celsius{job="proxmox-host",chip="pci0000:00_0000:00:18_3",sensor="temp1"} > bool 95)[7d:5m])
# CPU hôte et VM
avg_over_time((16 - sum(rate(node_cpu_seconds_total{job="proxmox-host",mode="idle"}[5m])))[24h:15m])
avg_over_time((12 - sum(rate(node_cpu_seconds_total{job="node-exporter",mode="idle"}[5m])))[24h:15m])
# CPU par pod (24 h) et p95
topk(30, sum by (namespace,pod) (rate(container_cpu_usage_seconds_total{container!="",image!=""}[24h])))
quantile_over_time(0.95, (sum by (namespace,pod) (rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m])))[24h:10m])
# Écritures NVMe, VM, ZIL
sum(rate(node_disk_written_bytes_total{job="proxmox-host",device="nvme0n1"}[24h]))
sum(rate(node_disk_written_bytes_total{job="node-exporter",device="sda"}[24h]))
rate(node_zfs_zil_zil_itx_metaslab_normal_bytes{job="proxmox-host"}[24h])
# Runners ARC
sum(increase(container_fs_writes_bytes_total{namespace="arc-runners",container!=""}[24h]))
# Règles burnrate et lecture du volume Prometheus
max(max_over_time(prometheus_rule_group_last_duration_seconds{rule_group=~".*burnrate.*"}[4h]))
sum(rate(node_disk_read_bytes_total{job="node-exporter",device="sdbs"}[30m]))
rate(container_network_transmit_bytes_total{pod=~"instance-manager.*"}[15m])
# Argo
sum by (name) (increase(argocd_app_sync_total[24h]))
# Restarts, PVC, pods
sum by (namespace,pod) (increase(kube_pod_container_status_restarts_total[7d]))
sum by (phase) (kube_persistentvolumeclaim_status_phase == 1)
sum by (phase) (kube_pod_status_phase)
```

`sdbs` est le périphérique du volume Prometheus dans la VM à la date de la
mesure ; il peut changer au redémarrage.
