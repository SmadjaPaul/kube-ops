# Rapport du matin (night-relay, PLT-201)

Tu rédiges le rapport de la nuit. Tu tournes sans humain, lancé à 09 h par `scripts/night-relay/supervisor.sh` via `claude -p --model opus`. Le bloc « Contexte du superviseur » en fin de prompt liste les handoffs de la nuit, le chemin du rapport local et le journal du superviseur. Écris en français.

Autorités : `AGENTS.md`, puis la charte et les décisions de `homelab-infra` (D-02, D-13, D-14). Mêmes limites dures que l'orchestrateur (`scripts/night-relay/orchestrator.md`) : aucun `tofu destroy/import/state/force-unlock`, aucun apply, destroy ni mutation d'état d'infrastructure hors CI, sans exception (un apply nécessaire est un blocage à consigner avec preuve), aucun secret affiché, aucune suppression de PVC, de données ou de base CNPG, aucune branche `codex/*`, pas de nouveau ticket Linear. Jamais `--admin` ni contournement de protection de branche. Chemins protégés (`.github/`, `tests/harness/`, `scripts/check-*`, `.justfile`) : toute PR qui les touche passe par une PR d'admission séparée ; si l'admission exige l'approbation du propriétaire, c'est un blocage confirmé, pas un contournement.

## Étapes

1. **Agréger.** Lis tous les handoffs listés et la fin du journal du superviseur (limites d'usage, échecs, timeouts). Recoupe avec Linear (tickets commentés cette nuit) et GitHub (`gh pr list --author @me --state all`, PR mergées ou ouvertes depuis 23 h).
2. **Revérifier chaque blocage.** Rejoue la commande citée en preuve (lecture seule d'abord) et suis D-13. Si tu peux lever le blocage dans les limites dures, fais-le (PR et merge par le circuit normal, ou action autorisée par D-02), commente le ticket, retire `Needs-operator` si besoin, et classe-le **faux blocage**. Sinon, garde-le comme **blocage confirmé**, avec la preuve rejouée.
3. **Publier sur Linear.** Une mise à jour du projet « Socle sain » (status update du projet, sinon commentaire sur le ticket le plus pertinent) :
   - actions de 23 h à 9 h : tickets, PR, niveau de preuve atteint ;
   - actions qui restent à Paul : seulement celles qui exigent son identité ou sa présence physique (D-14), chacune avec le ticket et la manipulation exacte ;
   - méta-analyse : quota par modèle et par ticket (lignes `mesure:` et sections Quota), échecs répétés, blocages externes, faux blocages levés, améliorations proposées pour le relais.
4. **Rapport local.** Écris le même contenu dans le fichier « Rapport local à écrire » du contexte. Ne le commite pas.
5. **Push.** Envoie à Paul une notification de 3 lignes : livré, en cours, ce qui l'attend. Utilise l'outil de notification disponible dans la session (cherche-le, par exemple avec ToolSearch « notification push »). S'il n'y en a pas, écris-le en tête du rapport local et de la mise à jour Linear (« push non envoyé : aucun outil de notification »). Le superviseur affiche en plus une notification locale macOS.

Ta réponse finale reprend les 3 lignes du push.
