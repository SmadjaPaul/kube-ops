# PLT-135 — Radio France dans Polyfin avec deux fichiers Eclipse statiques

## Décision

**Pas de Worker Cloudflare, pas de serveur HTTP supplémentaire, pas de redirection HTTP ni de relais audio.**

La radio FM est une URL HTTPS MP3 officielle. Polyfin n'accepte pas le MP3 audio-only dans **Live TV**, mais il sait lire les pistes d'un catalogue Eclipse avec un champ **`streamURL`**. Le protocole catalogue permet de publier le manifeste et la liste des stations en **deux fichiers JSON**, servis comme fichiers publics depuis le dépôt GitHub. Les URLs audio sont transmises directement dans les métadonnées ; seul le lecteur ou Polyfin (selon la politique de lecture) contacte Radio France.

Le point non prouvé reste **la lecture sans fin d'une piste de durée inconnue** : ne pas déclarer la fonctionnalité PASS avant un test réel de plusieurs minutes, arrêt/reprise et vérification du parcours `PlaybackInfo`.

## Références Polyfin v0.65.0

- `internal/eclipse/manifest.go` : un manifeste Eclipse doit avoir `id`, `name`, `version` et au moins une ressource ; `contentType: music` permet d'identifier le type. `resources: [catalog]` suffit au pilote catalogue sans source de recherche.
- `internal/eclipse/client.go` : GET `/catalog/stations?skip=0` revient à lire le fichier du catalogue et à décoder le JSON ; les pages comptent 100 éléments, et nos 8 entrées terminent l'énumération.
- `internal/library/music.go` : lorsqu'un track de catalogue inclut `streamURL` et `format`, la version conserve l'URL média sans exiger un endpoint `/stream/{id}`.
- `internal/jellyfin/audio.go` : les pistes MP3 passent par le lecteur audio, non par la détection de conteneur du Live TV.
- Docs : https://github.com/moodiness/polyfin/blob/v0.65.0/docs/music.md

## Fichiers statiques du pilote

- `integrations/polyfin-radio-eclipse/static/manifest.json`
- `integrations/polyfin-radio-eclipse/static/catalog/stations` (fichier **sans extension**, afin que le chemin Eclipse `/catalog/stations` fonctionne)
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

Après validation HTTP, installer l'addon Eclipse dans l'interface Polyfin depuis le manifeste, activer son catalogue et l'appeler **Radio**. Conserver l'addon Nebula/Musique sans changement, ainsi que les streams AIOStreams. **Ne pas utiliser Live TV pour les radios** ; conserver les huit anciennes chaînes audio-only désactivées.

Test utilisateur : FIP en lecture sur Brave **5 minutes**, arrêt/reprise, changement vers France Inter, navigation dans la vue **Songs / Morceaux** de la bibliothèque Radio pour trouver une station (sans recherche globale : les pages d'album et d'artiste ne peuvent pas énumérer les stations sans ressource Eclipse `search`), lecture depuis un autre client compatible, vérification des URLs de l'audio et du trafic éventuel via Cloudflare. Les flux sont des stations radio live sans durée de fin, pas des morceaux artificiels de 24 h. Si cela échoue, désactiver le catalogue Radio et documenter l'erreur exacte en vue d'un correctif upstream.

## Limitations et compromis

- Les deux fichiers JSON sont publics ; ils ne contiennent que des URLs de radios publiques.
- L'absence de la ressource search signifie que le catalogue Radio est navigable mais **pas interrogeable via la recherche globale Eclipse**. Avec seulement huit stations, c'est acceptable.
- Pas de logos ni de favoris spécifiques générés automatiquement ; les favoris peuvent dépendre du comportement Jellyfin client.
- La playlist Radio France officielle actuelle reste source d'inventaire, mais elle n'est pas installée comme Live TV utilisable.
- Le dépôt public GitHub et son Raw CDN sont une commodité sans engagement de service ; si cela pose problème, héberger les mêmes fichiers dans un serveur statique déjà existant.
- Ne pas ajouter Radio Browser tant que la solution fixe n'a pas passé ses tests.

## Objectif d'interface

**Radio · Musique · Films · Séries · Anime**.

Cinemeta fournit les bibliothèques Films/Séries, AIOStreams reste fournisseur de vidéo et Nebula reste fournisseur musique. La bibliothèque Anime est un chantier de catalogue/filtre distinct, à qualifier par l'interface native.
