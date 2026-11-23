# Home Assistant (hassio)

Socle de configuration minimal de la décision E de PLT-441 (as code : OpenTofu + provider
`toelke/homeassistant`, racine `homelab-infra/terraform/home-assistant`).

## Qui possède quoi

| Famille | Propriétaire | Où |
|---|---|---|
| `configuration.yaml` (socle) | Git (ce dossier, ConfigMap `ha-core-config`) | `config/configuration.yaml` |
| `automations.yaml`, `scripts.yaml`, `scenes.yaml` | **HA** (éditeur UI et provider OpenTofu) | PVC `/config`, **jamais Git** |
| Objets gérés par Git (préfixe `maison_`) | OpenTofu | `homelab-infra/terraform/home-assistant/desired/*.yaml` |
| `.storage`, `auth*`, `core.config_entries`, jetons | HA | PVC, jamais dans Git |

L'initContainer `init-ui-files` crée les trois fichiers vides (`[]`, `[]`, `{}`) s'ils manquent et
ne touche jamais à un fichier existant.

## Redémarrage

La ConfigMap est montée en `subPath` : un changement de `configuration.yaml` n'est relu qu'au
redémarrage du pod. Incrémenter `smadja.dev/config-rev` dans `statefulset.yaml`.

## Retour arrière

Revert de la PR puis incrémenter `smadja.dev/config-rev`. Les trois fichiers restent sur le PVC
(ignorés sans les `!include`). Filets : sauvegarde native HA et Velero.

## Sortie de secours

Si le provider disparaît, charger les `desired/*.yaml` en YAML simple, par exemple
`automation git: !include_dir_list <dossier>` (à côté de `automation: !include automations.yaml`).
