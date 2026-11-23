# Mises à jour de l'hôte Proxmox (tatouine) : alertes et backlog

Ticket : PLT-475. Conception : `docs/architecture/proxmox-updates.md` (homelab-infra), décision D-2026-11-23-03 (proposée).

## Chaîne

1. Sur l'hôte, le collecteur Debian `apt_info.py` (timer `prometheus-node-exporter-apt.timer`, toutes les 15 min) écrit `apt.prom` : `apt_upgrades_pending{origin}`, `apt_upgrades_held`, `apt_autoremove_pending`, `apt_package_cache_timestamp_seconds`, `node_reboot_required`. Il lit le cache APT local, il ne lance jamais `apt update` (c'est `apt-daily.timer` de l'hôte). Activé par le rôle homelab-infra `proxmox_node_exporter`.
2. Prometheus scrape le job `proxmox-host`. Le job ajoute `origin="proxmox"`, donc l'origine APT arrive sous `exported_origin`.
3. Les règles `proxmox-updates` (warning, non poussées sur ntfy) signalent l'état.
4. Le CronJob `monitoring/proxmox-updates-backlog` (lundi 07:00) lit Prometheus et tient à jour **un seul** ticket Linear « Proxmox tatouine : mises à jour en attente (ticket automatique) » (équipe PLT, projet Cluster et ressources, labels `cluster`, `J3`). Il ne contacte jamais l'hôte.
5. Paul fait la mise à jour depuis son poste avec `ansible/playbooks/proxmox-upgrade.yml` (homelab-infra). Jamais depuis la CI : les runners ARC tournent dans la VM Talos hébergée par cet hôte.

## Alertes

### ProxmoxSecurityUpdatesPending

**Signal** : des paquets dont l'origine contient `security` attendent depuis plus de 7 jours.
**Première vérification** : `sum by (exported_origin) (apt_upgrades_pending{job="proxmox-host"})` dans Prometheus, puis le ticket automatique.
**Action** : depuis le poste de Paul, `ansible-playbook ansible/playbooks/proxmox-upgrade.yml --check`, puis la même commande avec `-e proxmox_upgrade_confirm=tatouine`.

### ProxmoxRebootRequired

**Signal** : `/run/reboot-required` existe depuis plus de 7 jours.
**Première vérification** : `node_reboot_required{job="proxmox-host"}` et `node_uname_info{job="proxmox-host"}`.
**Action** : fenêtre de maintenance annoncée (le cluster s'arrête 5 à 10 min), puis le playbook avec `-e proxmox_upgrade_allow_reboot=true`. Limite : un nouveau noyau Proxmox ne crée pas toujours ce fichier ; le playbook compare aussi le noyau en cours au plus récent installé.

### ProxmoxAptIndexStale

**Signal** : l'index APT a plus de 3 jours.
**Première vérification** : `time() - apt_package_cache_timestamp_seconds{job="proxmox-host"}`.
**Action** : un dépôt échoue (souvent `pve-enterprise` en 401 sans souscription). Le rôle homelab-infra `proxmox_apt_repos` corrige les sources ; Paul l'applique avec `ansible/playbooks/proxmox-apt.yml`.

### ProxmoxAptTelemetryMissing

**Signal** : `apt_autoremove_pending` absent ou `apt.prom` vieux de plus d'une heure.
**Première vérification** : `node_textfile_mtime_seconds{job="proxmox-host"}` et `up{job="proxmox-host"}`.
**Action** : appliquer le rôle `proxmox_node_exporter` (`proxmox_node_exporter_enable_apt_updates: true`). Sans ces métriques, l'absence d'alerte ne prouve rien.

## Backlog Linear

- Clé : `PROXMOX_UPDATES_LINEAR_API_KEY` dans Doppler `cluster/prd` (clé Linear dédiée, créée par Paul). Sans elle, le job tourne à blanc et écrit le ticket dans ses journaux.
- Unicité : le job cherche un ticket ouvert à ce titre exact. S'il existe, il met à jour la description et la priorité ; sinon, et seulement si quelque chose est en attente, il en crée un. Ne pas renommer le ticket. Un ticket fermé n'est jamais rouvert : la semaine suivante, un nouveau est créé si des mises à jour sont encore en attente.
- Priorité : haute si sécurité en attente, redémarrage requis ou télémétrie absente ; moyenne sinon.
- Lancer à la main : `kubectl -n monitoring create job --from=cronjob/proxmox-updates-backlog proxmox-updates-backlog-manual` (geste de Paul ou d'un agent avec droit d'écriture sur `monitoring`).
