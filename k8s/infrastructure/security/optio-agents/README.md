# Optio — garde-fous des agents (namespace `optio`, assemblés par `kustomization.yaml`)

- `job-pod-nonroot.yaml` : ajoute le contexte non-root (uid 1001) aux pods d'agents qui n'en déclarent pas.
- `volume-retention.yaml` : supprime les volumes des StatefulSet Optio (rétention `Delete`).
- `priorityclass.yaml` : priorité `optio-maintenance` pour le CronJob de maintenance, hors quota des pods d'agents.
