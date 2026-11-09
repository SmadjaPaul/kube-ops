# PLT-135 / PLT-153 — Radio France dans Polyfin via Eclipse statique

## Décision

**Pas de Worker Cloudflare, pas de serveur HTTP supplémentaire, pas de redirection HTTP ni de relais audio.**

La radio FM est une URL HTTPS MP3 officielle. Polyfin n'accepte pas le MP3 audio-only dans **Live TV**, mais il sait lire les pistes d'un catalogue Eclipse avec un champ **`streamURL`**. Le protocole catalogue permet de publier le manifeste et la liste des stations en **deux fichiers JSON**, servis comme fichiers publics depuis le dépôt GitHub. Les URLs audio sont transmises directement dans les métadonnées ; seul le lecteur ou Polyfin (selon la politique de lecture) contacte Radio France.

**FIP en écoute continue cinq minutes, arrêt/reprise et France Inter sont déjà qualifiés PASS sur Polyfin 0.61.1.** Le passage de 8 à 17 stations (PLT-153) et leurs vignettes nécessite un contrôle runtime distinct après la fusion du catalogue.

## Références Polyfin v0.61.1 (version actuellement déployée)

- `internal/eclipse/manifest.go` : un manifeste Eclipse doit avoir `id`, `name`, `version` et au moins une ressource ; `contentType: music` permet d'identifier le type. `resources: [catalog]` suffit au pilote catalogue sans source de recherche.
- `internal/eclipse/client.go` : GET `/catalog/stations?skip=0` revient à lire le fichier du catalogue et à décoder le JSON ; les pages comptent 100 éléments, et nos 17 entrées terminent l'énumération.
- `internal/library/music.go` : lorsqu'un track de catalogue inclut `streamURL` et `format`, la version conserve l'URL média sans exiger un endpoint `/stream/{id}`.
- `internal/jellyfin/audio.go` : les pistes MP3 passent par le lecteur audio, non par la détection de conteneur du Live TV.
- Contrat : https://github.com/moodiness/polyfin/blob/v0.61.1/internal/eclipse/client.go (dont `artworkURL` sur Track)

## Fichiers statiques (17 stations, manifest 0.2.0)

- `integrations/polyfin-radio-eclipse/static/manifest.json`
- `integrations/polyfin-radio-eclipse/static/catalog/stations` (fichier **sans extension**, afin que le chemin Eclipse `/catalog/stations` fonctionne)
- `integrations/polyfin-radio-eclipse/static/artwork/*.png` (17 visuels typographiques originaux, un par station)
- `integrations/polyfin-radio-eclipse/static.test.mjs`

**URL à enregistrer dans Polyfin après fusion sur main :**

https://raw.githubusercontent.com/SmadjaPaul/kube-ops/main/integrations/polyfin-radio-eclipse/static/manifest.json

Polyfin calcule alors :

https://raw.githubusercontent.com/SmadjaPaul/kube-ops/main/integrations/polyfin-radio-eclipse/static/catalog/stations?skip=0

Le serveur GitHub Raw doit être capable de servir les deux ressources (statut HTTP 200 et réponse JSON parseable). Le type MIME du fichier sans extension peut être `text/plain` / `application/octet-stream` ; le parseur HTTP interne de Polyfin décode le JSON sans se fonder sur le type MIME déclaré. Cela reste **à confirmer depuis le cluster**. En cas de refus par GitHub Raw ou de limites, utiliser un hôte statique *déjà existant* avec des chemins identiques, pas un Worker.

## Tests

```sh
node --test integrations/polyfin-radio-eclipse/static.test.mjs
```

Vérifier par des HTTP GET **sans cookies ni secrets** les deux URLs ci-dessus. Le manifeste n'expose pas search/stream, donc aucune bibliothèque `Ma musique` supplémentaire n'est synthétisée.

L'addon existe déjà en production sous le même identifiant `dev.smadja.radio-france` et la bibliothèque `Radio` existe. Après fusion, actualiser le manifeste 0.2.0 et son catalogue, ou rafraîchir/réinstaller la même source **sans supprimer la bibliothèque ni ses favoris** si Polyfin ne met pas à jour le cache automatiquement. Conserver l'addon Nebula/Musique sans changement, ainsi que les streams AIOStreams. **Ne pas utiliser Live TV pour les radios** ; conserver les anciennes chaînes audio-only Live TV désactivées.

Test additionnel PLT-153 : contrôler **17 stations distinctes** et leurs vignettes, puis écouter **FIP Cultes**, **FIP Sacré français !** et trois autres nouveaux flux (30 secondes minimum par station). Le pilote initial FIP en lecture sur Brave **5 minutes**, arrêt/reprise, changement vers France Inter, navigation dans la vue **Songs / Morceaux** a déjà réussi. (sans recherche globale : les pages d'album et d'artiste ne peuvent pas énumérer les stations sans ressource Eclipse `search`), lecture depuis un autre client compatible, vérification des URLs de l'audio et du trafic éventuel via Cloudflare. Les flux sont des stations radio live sans durée de fin, pas des morceaux artificiels de 24 h. Si cela échoue, désactiver le catalogue Radio et documenter l'erreur exacte en vue d'un correctif upstream.

## Limitations et compromis

- Les deux fichiers JSON sont publics ; ils ne contiennent que des URLs de radios publiques.
- L'absence de la ressource search signifie que le catalogue Radio est navigable mais **pas interrogeable via la recherche globale Eclipse**. Avec 17 stations, la navigation par la vue Chansons reste acceptable.
- Chaque station dispose maintenant d'une image statique PNG identifiante via `artworkURL`. Ce sont des cartes graphiques originales, **pas les logos officiels FIP/Radio France**. Les favoris restent dépendants du comportement Jellyfin client.
- La playlist Radio France officielle actuelle reste source d'inventaire, mais elle n'est pas installée comme Live TV utilisable.
- Le dépôt public GitHub et son Raw CDN sont une commodité sans engagement de service ; si cela pose problème, héberger les mêmes fichiers dans un serveur statique déjà existant.
- Ne pas ajouter Radio Browser tant que la solution fixe n'a pas passé ses tests.

## Objectif d'interface

**Radio · Musique · Films · Séries · Anime**.

Cinemeta fournit les bibliothèques Films/Séries, AIOStreams reste fournisseur de vidéo et Nebula reste fournisseur musique. La bibliothèque Anime est un chantier de catalogue/filtre distinct, à qualifier par l'interface native.
