# État réel du cluster

**Première lecture de tout agent.** Cet état vient du cluster vivant (Argo, kubectl, Prometheus, Loki), pas des manifests. En cas de désaccord avec Git ou un ticket, ceci décrit le runtime observé ; Git reste l'autorité du désiré (AGENTS.md).

- Généré le 2026-11-11 18:10 UTC par `bash scripts/cluster-reality.sh` (lecture seule, idempotent, aucun secret).
- Cluster Kubernetes v1.36.3, 30 Applications Argo, 60 lignes (namespaces ; drills regroupés).
- En marche : 51 ; à l'arrêt/dégradé : 6 (agent-observers, drills/recovery (15 ns), executor, it-tools, kubechecks, openclaw-operator-system) ; sans workload : 3.
- Verdicts : ALLÉGER 11, DÉPLACER-ORACLE 1, GARDER 46, RETIRER 2.
- Applications Argo hors Synced/Healthy : apps-ai (Synced/Unknown), apps-platform (OutOfSync/Progressing).
- CPU/RAM : moyenne et pic sur 24 h (Prometheus, sous-requête 5 min, somme des conteneurs par namespace ; RAM = working set).
- Dernier accès utilisateur : non mesurable (Envoy Cilium n'émet aucun journal d'accès HTTP dans Loki ; aucune métrique par route). Activer les access logs Gateway pour mesurer.
- Authentification : « OIDC » = secret/variable OIDC-Authentik détecté sur le workload (par nom, jamais par valeur) ; il n'y a pas de protection au niveau Gateway. « auth non détectée » = à vérifier.
- Verdicts : jugement par table explicite dans `scripts/lib/cluster_reality_render.py`, selon la charte, D-05, D-06, D-07 ; RETIRER seulement sur décision ou absence d'usage et de données.

## Top consommateurs (24 h)

- CPU moyen : kube-system 0.63, longhorn-system 0.46, arc-runners 0.37, argocd 0.11, monitoring 0.10
- CPU pic : kube-system 1.44, arc-runners 1.42, longhorn-system 1.03, factory-platform 0.90, argocd 0.61
- RAM moyenne (Mi) : kube-system 4585, longhorn-system 3438, monitoring 1941, hindsight-personal 1553, argocd 1155
- RAM pic (Mi) : kube-system 5354, longhorn-system 4038, monitoring 2226, arc-runners 1822, hindsight-personal 1647
- Total cluster : CPU moy 2.28 cœurs, RAM moy 27.2 Gi.

## Applications

| Namespace | Argo | État | CPU moy/pic (cœurs) | RAM moy/pic (Mi) | Route / exposition | Classe D-05 | Verdict |
|---|---|---|---|---|---|---|---|
| drills/recovery (15 ns) | mixte | 0/15 ns actifs | 0.033/0.048 | 694/792 | — | reconstructible (PVC 28/236Gi, CNPG 3) | **ALLÉGER** : drills éphémères ; purger après preuve, suppression PVC = Paul (D-13), candidats RETIRER |
| executor | apps-ai | NON scaled 0 | —/— | —/— | executor.smadja.dev [LAN] auth non détectée | reconstructible (PVC 1/10Gi) | **ALLÉGER** : préparé à 0 réplica dans Git ; activer ou retirer, décision Factory (D-09) |
| factory-platform | apps-platform | OUI 3/3 | 0.087/0.902 | 170/417 | aucune | reconstructible (PVC 5/52Gi, CNPG 2) | **GARDER** : Factory MVP (D-09) |
| gpt-researcher | apps-ai | OUI 3/3 | 0.003/0.006 | 839/956 | research.smadja.dev [public] auth non détectée | reconstructible (PVC 3/25Gi) | **ALLÉGER** : usage non mesurable ; candidat scale 0 si inutilisé |
| hindsight-personal | personal-hindsight | OUI 1/1 | 0.011/0.081 | 1553/1647 | aucune | irremplaçable (à confirmer) (PVC 2/15Gi, CNPG 1) | **GARDER** : mémoire d'agent, utilité à confirmer (D-05) |
| home-assistant | apps-automation | OUI 1/1 | 0.000/0.002 | 417/536 | hassio.smadja.dev [public] OIDC | irremplaçable (à confirmer) (PVC 1/5Gi) | **GARDER** : config domotique ; cible N100 (D-11, proposée) |
| immich | apps-media | OUI 3/3 | 0.025/0.031 | 1096/1201 | immich.smadja.dev [public] OIDC | irremplaçable (PVC 4/136Gi, CNPG 1) | **GARDER** : photos/vidéos originales (D-05) |
| invoice-ninja | apps-invoice-ninja | OUI 3/3 | 0.032/0.044 | 1052/1132 | gestion.lechaplais.com [public] OIDC | irremplaçable (PVC 4/17Gi) | **GARDER** : factures (D-05) |
| it-tools | apps-tools | NON scaled 0 | —/— | —/— | ittools.smadja.dev [public] auth non détectée | reconstructible | **GARDER** : sans état, scale-to-zero KEDA voulu (#405), coût nul |
| karakeep | apps-ai | OUI 3/3 | 0.013/0.017 | 483/570 | karakeep.smadja.dev [public] OIDC | irremplaçable (à confirmer) (PVC 2/10Gi) | **GARDER** : marque-pages ; à confirmer |
| mastra-factory | apps-platform | OUI 1/1 | 0.009/0.046 | 416/469 | factory.smadja.dev [LAN] OIDC | reconstructible (PVC 2/25Gi, CNPG 1) | **GARDER** : Factory MVP (D-09) |
| matrix | apps-platform | OUI 4/4 | 0.020/0.029 | 441/491 | chat.smadja.dev [public]; account.smadja.dev [public] +2 OIDC | irremplaçable (à confirmer) (PVC 5/90Gi, CNPG 2) | **GARDER** : messagerie famille, à confirmer |
| mealie | apps-catalog | OUI 1/1 | 0.001/0.001 | 235/273 | mealie.smadja.dev [public] OIDC | irremplaçable (à confirmer) (PVC 1/5Gi) | **GARDER** : recettes, lecture Hermes (D-08) |
| media | apps-media | OUI 4/4 | 0.030/0.083 | 535/794 | aiostreams.smadja.dev [LAN]; tv.smadja.dev [public] +2 OIDC | reconstructible (PVC 6/2084Gi, CNPG 1) | **DÉPLACER-ORACLE** : AIOStreams + Polyfin candidats Oracle (D-07, hypothèse pilote) |
| mqtt | apps-automation | OUI 1/1 | 0.000/0.000 | 2/3 | aucune | reconstructible (PVC 1/1Gi) | **GARDER** : bus domotique ; cible N100 (D-11, proposée) |
| ntfy | apps-catalog | OUI 1/1 | 0.000/0.003 | 13/17 | ntfy.smadja.dev [public] auth non détectée | reconstructible (PVC 1/1Gi) | **GARDER** : notifications |
| open-connector | apps-platform | OUI 1/1 | 0.000/0.001 | 79/85 | aucune | reconstructible (PVC 1/2Gi) | **GARDER** : connecteurs agents |
| opencode | apps-ai | OUI 1/1 | 0.018/0.022 | 565/651 | opencode.smadja.dev [public] auth non détectée | reconstructible (PVC 2/15Gi) | **GARDER** : poste agent (D-13) |
| paperless | apps-catalog | OUI 2/2 | 0.013/0.213 | 787/842 | paperless.smadja.dev [LAN] auth non détectée | irremplaçable (PVC 3/35Gi, CNPG 1) | **GARDER** : documents (D-05) |
| pinepods | apps-web | OUI 2/2 | 0.008/0.014 | 162/238 | pinepods.smadja.dev [public] OIDC | reconstructible (PVC 3/93Gi, CNPG 1) | **GARDER** : podcasts re-téléchargeables |
| romm | apps-games | OUI 1/1 | 0.013/0.108 | 522/528 | romm.smadja.dev [public] OIDC | reconstructible (à confirmer) (PVC 6/157Gi, CNPG 1) | **GARDER** : bibliothèque ROM ; usage à mesurer |
| rustical-pilot | apps-platform | OUI 1/1 | 0.005/0.007 | 10/23 | calendar.smadja.dev [LAN] OIDC | irremplaçable (PVC 2/2Gi) | **GARDER** : calendriers/contacts (D-05) |
| searxng | apps-catalog | OUI 1/1 | 0.000/0.000 | 112/139 | search.smadja.dev [LAN] auth non détectée | reconstructible | **GARDER** : méta-recherche sans état |
| stirling-pdf | apps-catalog | OUI 1/1 | 0.010/0.022 | 791/1153 | pdf.smadja.dev [LAN] auth non détectée | reconstructible (PVC 1/2Gi) | **GARDER** : outil PDF sans état |
| sure | apps-catalog | OUI 3/3 | 0.010/0.063 | 905/954 | sure.smadja.dev [LAN] OIDC | irremplaçable (à confirmer) (PVC 2/15Gi, CNPG 1) | **GARDER** : finances perso, à confirmer |
| trilium | apps-web | OUI 1/1 | 0.000/0.001 | 109/160 | trilium.smadja.dev [public] auth non détectée | irremplaçable (à confirmer) (PVC 1/5Gi) | **GARDER** : notes personnelles |
| vikunja | apps-catalog | OUI 1/1 | 0.007/0.011 | 119/178 | tasks.smadja.dev [public] OIDC | irremplaçable (à confirmer) (PVC 2/7Gi, CNPG 1) | **GARDER** : tâches ; à confirmer |
| wellness | personal-sparkyfitness | OUI 3/3 | 0.006/0.041 | 356/398 | fitness.smadja.dev [LAN] OIDC | irremplaçable (PVC 3/8Gi, CNPG 1) | **GARDER** : santé/sport (SparkyFitness, D-05) |

## Socle, contrôleurs et retraits décidés

| Namespace | Argo | État | CPU moy/pic (cœurs) | RAM moy/pic (Mi) | Route / exposition | Classe D-05 | Verdict |
|---|---|---|---|---|---|---|---|
| agent-observers | infra-controllers | NON scaled 0 | —/— | —/— | aucune | socle | **GARDER** : observateurs agents |
| agent-sandbox-system | infra-controllers | OUI 1/1 | 0.001/0.002 | 26/65 | aucune | socle | **GARDER** : sandbox agents (Factory) |
| agentgateway | apps-platform | OUI 1/1 | 0.000/0.002 | 13/56 | aucune | socle (PVC 1/1Gi) | **GARDER** : passerelle agents/MCP |
| arc-runners | apps-arc-factory-ci | sans workload | 0.366/1.423 | 614/1822 | aucune | socle | **GARDER** : CI self-hosted |
| arc-systems | infra-arc-controller | OUI 1/1 | 0.001/0.003 | 66/116 | aucune | socle | **GARDER** : CI self-hosted |
| argo-rollouts | infra-controllers | OUI 1/1 | 0.001/0.002 | 28/89 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |
| argocd | infra-controllers | OUI 6/6 | 0.108/0.612 | 1155/1578 | argocd.smadja.dev [public] OIDC | socle | **GARDER** : reconciler unique |
| atlantis-apps | infra-atlantis-apps | sans workload | —/— | —/— | aucune | reconstructible (PVC 1/5Gi) | **RETIRER** : Atlantis retiré ; PVC de recovery gardé jusqu'à validation (suppression = Paul, D-13) |
| atlantis-system | infra-atlantis-plan-only | sans workload | 0.001/0.004 | 43/44 | aucune | reconstructible (PVC 1/5Gi) | **RETIRER** : Atlantis retiré ; PVC de recovery gardé jusqu'à validation (suppression = Paul, D-13) |
| auth | infra-auth | OUI 3/3 | 0.096/0.163 | 1108/1248 | auth.smadja.dev [public] IdP | irremplaçable (PVC 2/70Gi, CNPG 1) | **GARDER** : Authentik = autorité d'identité |
| cert-manager | infra-controllers | OUI 3/3 | 0.001/0.003 | 131/260 | aucune | socle | **GARDER** : TLS |
| cloudflared | infra-network | OUI 1/1 | 0.002/0.007 | 21/33 | aucune | socle | **GARDER** : accès public (tunnel) |
| cnpg-system | infra-database | OUI 2/2 | 0.007/0.023 | 131/181 | aucune | socle | **GARDER** : opérateur Postgres/Barman |
| csi-proxmox | infra-storage | OUI 2/2 | 0.005/0.009 | 88/244 | aucune | socle | **GARDER** : stockage |
| external-dns-private | infra-network | OUI 1/1 | 0.000/0.001 | 29/130 | aucune | socle | **GARDER** : DNS privé |
| external-secrets | infra-controllers | OUI 3/3 | 0.002/0.008 | 141/224 | aucune | socle | **GARDER** : Doppler -> ESO |
| falco | infra-security | OUI 3/3 | 0.064/0.139 | 333/385 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |
| gatekeeper-system | infra-security | OUI 2/2 | 0.026/0.060 | 287/336 | aucune | socle | **ALLÉGER** : D-06 : retrait après conversion des contraintes vers Kyverno |
| keda | infra-controllers | OUI 6/6 | 0.008/0.011 | 146/459 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |
| kube-system | infra-network | OUI 6/6 | 0.631/1.441 | 4585/5354 | hubble.smadja.dev [LAN] auth non détectée | socle | **GARDER** : CNI, CoreDNS, Hubble |
| kubechecks | infra-deployment | NON scaled 0 | —/— | —/— | kubechecks.smadja.dev [public] auth non détectée | socle | **ALLÉGER** : déjà à 0 réplica ; D-06 retrait sur preuve (route publique résiduelle à fermer) |
| kubelet-serving-cert-approver | hors Argo | OUI 1/1 | 0.000/0.002 | 19/21 | aucune | socle | **GARDER** : certificats kubelet |
| kyverno | infra-security | OUI 4/4 | 0.015/0.058 | 210/532 | aucune | socle | **GARDER** : moteur de policy cible (D-06) |
| longhorn-system | infra-storage | OUI 10/10 | 0.462/1.031 | 3438/4038 | aucune | socle | **GARDER** : stockage |
| metrics-server | infra-controllers | OUI 1/1 | 0.002/0.002 | 35/83 | aucune | socle | **GARDER** : métriques HPA/top |
| monitoring | infra-monitoring | OUI 11/11 | 0.102/0.191 | 1941/2226 | alertmanager.smadja.dev [LAN]; grafana.smadja.dev [LAN] +1 OIDC | socle (PVC 2/40Gi) | **GARDER** : Prometheus/Loki/Grafana ; Tempo/Alloy à justifier |
| node-feature-discovery | infra-controllers | OUI 3/3 | 0.001/0.003 | 35/123 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |
| openclaw-operator-system | openclaw-operator | NON CrashLoop x1 | 0.003/0.005 | 13/53 | aucune | reconstructible | **GARDER** : opérateur OpenClaw desired state SUSPENDU via GitOps (replicas 0, PLT-217) ; CRD openclaw.rocks conservées |
| reloader | infra-controllers | OUI 1/1 | 0.000/0.005 | 26/60 | aucune | socle | **GARDER** : rollout sur changement de secret |
| trivy-system | infra-security | OUI 1/1 | 0.011/0.161 | 400/627 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |
| velero | infra-controllers | OUI 2/2 | 0.005/0.043 | 269/507 | aucune | socle | **GARDER** : sauvegarde Kopia (D-05) |
| vertical-pod-autoscaler | infra-controllers | OUI 1/1 | 0.001/0.002 | 44/64 | aucune | socle | **ALLÉGER** : D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier |

## Manifests dans Git mais absents du cluster

Répertoires `k8s/applications`, `k8s/infrastructure`, `k8s/optional`, `k8s/poc` (niveau application) qui ne sont atteints par aucune racine Argo/Kustomize : ils ne sont pas déployés.

- `k8s/applications/ai/perplexica`
- `k8s/applications/ai/pocket-tts`
- `k8s/applications/ai/vllm-embed`
- `k8s/applications/automation/matter-server`
- `k8s/applications/automation/zigbee2mqtt`
- `k8s/applications/media/arr`
- `k8s/applications/media/audiobookshelf`
- `k8s/applications/media/bookorbit`
- `k8s/applications/media/jellyfin` (retiré par décision)
- `k8s/applications/media/jellyseerr` (retiré par décision)
- `k8s/applications/media/rdt-client`
- `k8s/applications/media/recyclarr` (retiré par décision)
- `k8s/applications/media/sabnzbd`
- `k8s/applications/media/whisperasr`
- `k8s/infrastructure/controllers/nvidia-gpu-operator`
- `k8s/infrastructure/network/gateway-api-crds`
- `k8s/optional/arr-external-auth`
- `k8s/optional/lasuite`
- `k8s/optional/polyfin-v059`
- `k8s/optional/polyfin-v060`
- `k8s/poc/atlantis-infra`

Total : 21.
