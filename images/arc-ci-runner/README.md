# arc-ci-runner

Image commune des scale sets ARC (`kube-ops-ci-arc`, `homelab-infra-ci-arc`,
`homelab-iac-pilot-arc`, `website-ci-arc`, `agent-harness-ci-arc`) :
`ghcr.io/actions/actions-runner` (digest épinglé) plus tous les outils de CI
préinstallés, pour qu'un job ne télécharge plus rien.

| Source | Contenu |
|---|---|
| `mise.toml` + `mise.lock` | shellcheck, shfmt, jq, yq, gh, gitleaks, tofu, terraform, tflint, terraform-docs, pre-commit, yamllint, zizmor, helm, kustomize, kubeconform, kyverno, pnpm, just, uv, actionlint, conftest, ruby, Node 22/24/26. Installés en `--locked` dans `/usr/local/share/mise/installs`. |
| `package.json` + `package-lock.json` | CLI `claude` (agent-harness : `claude plugin validate`). |
| `Dockerfile` | apt (libatomic1, xz-utils, python3, pip, venv), mise, liens dans `/usr/local/bin`, Node dans `/opt/hostedtoolcache` (actions/setup-node ne télécharge rien), Chromium de Playwright (website). |

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
`images/`), vers `ghcr.io/smadjapaul/arc-ci-runner`. Bascule d'un scale set :
`image: ghcr.io/smadjapaul/arc-ci-runner:<tag>@sha256:<digest publié>` dans son
`runner-application.yaml`.

## Suivi automatique des versions

- Source de vérité : les fichiers de version des dépôts (`.node-version`, `mise.toml`, `.tool-versions`...) ; l'image en porte une copie dans `mise.toml`.
- Le manifeste `/etc/arc-ci-runner/tools.json` (sortie de `mise ls --installed --json`) liste les versions embarquées ; le label OCI `io.github.smadjapaul.arc-ci-runner.manifest` indique son chemin.
- Un workflow de dérive (quotidien et au push sur ce dossier) compare ces fichiers à `mise.toml` et ouvre une PR qui ajoute la version manquante, sans retirer celles encore utilisées.
- Fail-open : un outil absent de l'image est téléchargé par setup-node ou mise ; la CI ralentit mais ne casse pas.
- Les jobs signalent « outil téléchargé, absent de l'image » dans `$GITHUB_STEP_SUMMARY`.
