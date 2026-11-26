# Optio : outils de contrôle dans le pod d'agent (PLT-535)

## Pourquoi

Le 26/11, le pod d'agent n'avait ni `shellcheck`, ni `helm`, ni `kubectl`, ni le module Python `yaml`, ni
`jq` à la version du dépôt : les contrôles du dépôt échouaient et une tâche s'est bloquée. Optio 0.26.4
exécute `.optio/setup.sh` à la préparation du pod d'agent, avant tout agent ; ce script installe les
outils de contrôle, et `scripts/optio/preflight.sh` dit ensuite ce que le pod peut faire.

Exploitation générale : [optio.md](optio.md) — règles de revue : [optio-review.md](optio-review.md).

## Le contrat d'outils

| Source | Rôle |
|---|---|
| `mise.toml` | versions exactes des outils (section `[tools]`) |
| `mise.lock` | URL de l'artefact et somme de contrôle sha256, par plateforme (`linux-x64`, `linux-arm64`) |

Les deux fichiers sont lus au moment de l'installation : une version, une URL ou une somme qui change dans
le dépôt change l'installation, sans retoucher le script.

## Ce que fait `.optio/setup.sh`

- **Sans privilège** : tout est écrit dans `$HOME/.local/bin`, déjà en tête du PATH des execs de tâche
  d'Optio et de l'image agent. Aucun `sudo`, aucun paquet système, aucune écriture dans le dépôt.
- **Versions exactes et sommes de contrôle** : la somme `mise.lock` est vérifiée avant installation ; un
  artefact qui ne correspond pas est jeté, rien n'est installé.
- **Idempotent** : un outil déjà à la bonne version n'est pas réinstallé. Une seconde exécution dure
  moins d'une seconde.
- **Budget de 4 minutes** (240 s, la tâche en impose 5) : passé ce délai, les outils restants sont
  signalés ABSENT, pas installés.
- **Code de retour toujours nul** : `scripts/repo-init.sh` de l'API Optio est en `set -e` et exécute ce
  script ; un code non nul empêcherait le pod de démarrer. Une installation impossible est signalée,
  jamais fatale.
- **Une ligne par outil** : `SETUP_TOOL=OK tool=<nom> version=<voulue> state=<installed|already_present>`
  ou `SETUP_TOOL=ABSENT tool=<nom> version=<voulue> reason=<raison>`, puis une ligne `SETUP_SUMMARY=...`.

Les hôtes autorisés sont ceux déjà autorisés aux pods d'agents par la CiliumNetworkPolicy `optio-agents`
(`k8s/applications/platform/optio/networkpolicy.yaml`) : `github.com`, `objects.githubusercontent.com`,
`pypi.org`, `files.pythonhosted.org`, `registry.npmjs.org`. **Aucune règle réseau n'est modifiée** : un
outil dont l'artefact vient d'un autre hôte est signalé ABSENT, pas installé.

## Liste des outils

| Outil | Version | Hôte de l'artefact | État |
|---|---|---|---|
| `jq` | 1.8.2 | github.com | installé |
| `yq` | 4.54.3 | github.com | installé |
| `just` | 1.59.0 | github.com | installé |
| `kustomize` | 5.8.3 | github.com | installé |
| `shellcheck` | 0.11.0 | github.com | installé |
| `python` | 3.12.13 | github.com | installé (site-packages) |
| `kubeconform` | 0.8.0 | github.com | installé |
| `ripgrep` | 14.1.1 | github.com | installé (binaire `rg`) |
| `prek` | 0.5.11 | github.com | installé |
| `vale` | 3.28.1 | github.com | installé |
| `kyverno` | 1.20.0 | github.com | installé |
| `pyyaml` | 6.0.2 | pypi.org, files.pythonhosted.org | installé (module du python épinglé) |
| `node` | 26.13.1 | nodejs.org | déjà dans l'image du pod (hôte non autorisé, non installé par le script) |
| `helm` | 4.3.2 | get.helm.sh | **absent** : hôte non autorisé |
| `kubectl` | 1.36.3 | dl.k8s.io | **absent** : hôte non autorisé |

## Les outils restés absents

Depuis PLT-541 (26/11/2026), les pods d'agents joignent les adresses publiques en 80 et 443 : les hôtes
`get.helm.sh` et `dl.k8s.io` ne sont plus refusés par le réseau. Les constats ci-dessous datent d'avant ;
`.optio/setup.sh` et le contrôle préalable ne sont pas encore adaptés.

- **`helm`** (`get.helm.sh`) : 32 racines Kustomize utilisent `helmCharts`, donc `kustomize build
  --enable-helm` — le rendu du dépôt — ne peut pas aboutir dans le pod. La porte complète (`just check`)
  et la porte des racines affectées (`just check-affected`, qui rend toutes les racines dès qu'un
  fichier `scripts/` change) ne peuvent donc pas passer dans le pod ; les contrôles qui n'ont besoin que
  de `jq`, `yq`, `shellcheck`, `kyverno` et du module `yaml` fonctionnent. Lever cette limite suppose
  d'ajouter `get.helm.sh` à la liste FQDN sortante des pods d'agents : c'est une décision réseau, pas un
  script, elle n'est pas prise ici.
- **`kubectl`** (`dl.k8s.io`) : le pod n'a ni CLI Doppler ni jeton d'accès cluster ; la lecture du
  cluster passe par `scripts/kubectl-ro.sh`, qui n'a pas de source utilisable dans le pod. Les contrôles
  du pod sont statiques (Git), comme le veut le modèle de l'agent.
- **`node`** (`nodejs.org`) : l'image de l'agent embarque déjà node à la version de `.nvmrc` (26.13.1) ;
  le script ne le réinstalle pas.

## Contrôle préalable

```bash
bash scripts/optio/preflight.sh
```

Le script lit le même contrat (`mise.toml` pour les versions, `mise.lock` pour les hôtes) et affiche la
version réellement trouvée pour chaque outil :

```
PREFLIGHT=OK tool=jq version=1.8.2 expected=1.8.2 path=/home/agent/.local/bin/jq
PREFLIGHT=ABSENT tool=helm expected=4.3.2 reason=host_not_allowed host=get.helm.sh
PREFLIGHT=MISSING tool=shellcheck expected=0.11.0 reason=not_installed
PREFLIGHT=PASS required=6 checked=15 missing=0 mismatch=0 absent=2
```

- `OK` : l'outil est là, à la version voulue.
- `MISMATCH` : l'outil est là, mais à une autre version ; signalé, sans faire échouer le contrôle.
- `ABSENT` : le pod ne peut pas télécharger cet outil (hôte non autorisé) ; signalé, sans faire échouer
  le contrôle.
- `MISSING` : l'outil aurait pu être installé et ne l'est pas.

Code de retour : **1** si un outil requis manque — `jq`, `yq`, `kustomize`, `shellcheck`, `just` et le
module Python `yaml` — (la ligne `PREFLIGHT=FAIL` nomme les coupables), **0** sinon, **2** si le contrat
d'outils du dépôt est illisible.

## Notes d'exploitation

- `$HOME/.local/bin` doit être en tête du PATH : c'est le cas dans l'image agent et dans les execs de
  tâche d'Optio. Le script ne modifie aucun fichier de profil.
- PyYAML est installé dans le site-packages du python épinglé, pas dans le site utilisateur : les
  contrôles du dépôt lisent le module avec `python3 -I` (mode isolé), qui ignore le site utilisateur.
  `scripts/policy-check.sh --tests` n'a donc plus besoin de créer son venv épinglé.
- Le pod d'agent n'a pas d'accès au cluster : `scripts/kubectl-ro.sh` y reste inutilisable, faute de
  source de kubeconfig.

## Retour arrière

Revert de la PR : les pods suivants ne réinstallent plus rien. Les outils déjà installés restent dans le
PVC `/home/agent` ; pour revenir à l'état initial, supprimer les binaires installés dans
`$HOME/.local/bin` (et `$HOME/.local/python`).
