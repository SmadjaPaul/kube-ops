# arc-ci-runner

Image commune des scale sets ARC (`kube-ops-ci-arc`, `homelab-infra-ci-arc`,
`homelab-iac-pilot-arc`, `website-ci-arc`, `agent-harness-ci-arc`) :
`ghcr.io/actions/actions-runner` (digest épinglé) plus tous les outils de CI
préinstallés, pour qu'un job ne télécharge plus rien.

Multi-arch : `linux/amd64` (homelab) et `linux/arm64` (OKE A1,
`kube-ops-oke-arc`). Le digest publié est celui de l'index OCI ; chaque nœud
tire la variante de son arch. Le Dockerfile choisit le binaire mise et le
dossier du cache d'outils (`x64` ou `arm64`) selon `TARGETARCH`. `mise.lock`
porte `linux-x64` et `linux-arm64` pour chaque outil binaire. Le fichier
`platforms` liste les plateformes construites.

| Source | Contenu |
|---|---|
| `mise.toml` + `mise.lock` | shellcheck, shfmt, jq, yq, gh, gitleaks, tofu, terraform, tflint, terraform-docs, pre-commit, yamllint, zizmor, helm, kustomize, kubeconform, kyverno, pnpm, just, uv, actionlint, conftest, ruby, Node 22/24/26. Installés en `--locked` dans `/usr/local/share/mise/installs`. |
| `package.json` + `package-lock.json` | CLI `claude` (agent-harness : `claude plugin validate`). |
| `Dockerfile` | apt (libatomic1, xz-utils, python3, pip, venv), mise, liens dans `/usr/local/bin`, Node dans `/opt/hostedtoolcache` (actions/setup-node ne télécharge rien), Chromium de Playwright (website), `drift.py` dans `/usr/local/share/arc-ci-runner/`. |
| `platforms` | Plateformes construites par `image-build.yaml` (une par ligne). |

pnpm : la version fait foi dans chaque dépôt (`packageManager` de website, puis
son propre `mise.lock`). Le dépôt ne compte pas sur corepack, que Node 25+ ne
distribue plus. L'image porte une copie préchauffée, égale à `packageManager` de
website, parce que la CI de website la vérifie. Renovate ne monte pas pnpm ici.
Quand un dépôt change de version, `arc-ci-runner-drift` ajoute cette version.

Mises à jour : Renovate met à jour `mise.toml`/`mise.lock` (gestionnaire mise),
`package.json`, l'ARG `MISE_VERSION` et le digest de l'image amont. Playwright
(`PLAYWRIGHT_VERSION`) suit `scripts/visual/playwright-version.txt` du dépôt
website : à changer ensemble, à la main.

`mise.toml` part de celui de homelab-infra (mêmes versions que son `mise.lock`).
Si homelab-infra change une version avant le prochain build de l'image,
`mise install --locked` ne télécharge que l'outil modifié dans le HOME éphémère
du job ; reporter ensuite la version ici.

Contrôle de build : la dernière étape du Dockerfile lance les outils et vérifie
que `mise install --locked` ne télécharge rien (`MISE_OFFLINE=1`) depuis un HOME
vierge.

Publication : workflow `Build and Push Docker Images` (push sur main touchant
`images/`), vers `ghcr.io/smadjapaul/arc-ci-runner`. Chaque plateforme est
construite sur un runner natif (`ubuntu-latest` pour amd64, `ubuntu-24.04-arm`
pour arm64, sans QEMU) et poussée sous `<révision>-<arch>`. Un job assemble
ensuite l'index multi-arch et écrit son digest dans le résumé du run. Bascule
d'un scale set : `image: ghcr.io/smadjapaul/arc-ci-runner:<tag>@sha256:<digest
de l'index>` dans son `runner-application.yaml` (ou `values.yaml` sur OKE).

## Suivi automatique des versions

- Source de vérité : les fichiers de version des dépôts (`.node-version`, `mise.toml`, `.tool-versions`...) ; l'image en porte une copie dans `mise.toml`.
- Le manifeste `/etc/arc-ci-runner/tools.json` (sortie de `mise ls --installed --json`) liste les versions embarquées ; le label OCI `io.github.smadjapaul.arc-ci-runner.manifest` indique son chemin.
- Le workflow `arc-ci-runner-drift` (quotidien et au push sur ce dossier, script `drift.py`) compare ces fichiers à `mise.toml` et ouvre une PR qui ajoute la version manquante, sans retirer celles encore utilisées.
- Fail-open : un outil absent de l'image est téléchargé par setup-node ou mise ; la CI ralentit mais ne casse pas.
- Les jobs signalent « outil téléchargé, absent de l'image » dans `$GITHUB_STEP_SUMMARY`.
- Dans un job sur un runner ARC : `python3 /usr/local/share/arc-ci-runner/drift.py --local .` écrit la dérive dans `$GITHUB_STEP_SUMMARY` (ne casse jamais le job). Le script est dans l'image, donc épinglé par son digest : aucun téléchargement.
- Hors image (runner hébergé) : télécharger `drift.py` à un SHA de commit précis, vérifier sa somme, puis l'exécuter. Ne jamais l'envoyer dans `python3 -` depuis `main`.

  ```bash
  rev=<SHA de commit de kube-ops>
  curl -fsSLo drift.py "https://raw.githubusercontent.com/SmadjaPaul/kube-ops/$rev/images/arc-ci-runner/drift.py"
  echo "<sha256 de drift.py à ce commit>  drift.py" | sha256sum -c -
  python3 drift.py --local .
  ```
- Les dépôts privés exigent le secret `ARC_DRIFT_TOKEN` (lecture de contenu) ; sans lui seuls les dépôts publics sont lus et rien n'est retiré. Les PR ouvertes avec `GITHUB_TOKEN` ne lancent pas la CI : fermer/rouvrir ou utiliser ce jeton.
