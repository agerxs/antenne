# Antenne

Lecteur IPTV pour Mac et iPhone (SwiftUI, une seule cible multiplateforme).

- Comptes Xtream Codes (serveur, utilisateur, mot de passe) : Direct, Films et Séries par
  catégorie via `player_api.php`, chargés à l'ouverture et gardés en cache ; fiche série avec
  saisons et épisodes. Mot de passe dans le trousseau.
- Playlists M3U / M3U8 par lien (actualisables) ou par fichier importé
- Chaînes avec logos, filtre par groupe, recherche, favoris
- Lecture avec le lecteur d'Apple (AVKit) : plein écran, Picture in Picture, AirPlay
- `#EXTVLCOPT:http-user-agent` respecté ; les flux `.ts` sont retentés en `.m3u8` (Xtream)

## Structure

- `Antenne/` : l'app (vues, lecteur)
- `AntenneCore/` : paquet Swift testable (parseur M3U, client Xtream, stockage, URL de flux)
- `scripts/diagnostic-flux.sh` : état d'un compte Xtream et test d'un échantillon de flux avec ffprobe
- `Config/` : Info.plist (ATS ouvert pour les flux http) et entitlements macOS

## Lancer

Ouvrir `Antenne.xcodeproj`, choisir « My Mac » ou l'iPhone branché, puis Run.
La signature est automatique avec l'équipe `GF98TAKX7X`.

Tests du cœur :

```bash
cd AntenneCore && swift test
```

## Limites connues

Le lecteur d'Apple ne lit que le HLS (`.m3u8`) et les fichiers MP4/MOV. Le MPEG-TS brut,
le RTMP et certains codecs (MPEG-2, AC-3 selon l'appareil) échouent avec un message clair.
Les intégrer demanderait VLCKit.

Pour un compte Xtream, la recherche porte sur les noms de catégories et les titres des
catégories déjà ouvertes : l'API ne permet pas de chercher dans tout le catalogue sans le
télécharger (plus de 500 000 entrées chez certains fournisseurs).

Les liens de flux Xtream contiennent identifiant et mot de passe : le cache des réponses n'en
contient pas (les liens sont reconstruits à la volée), mais une chaîne mise en favori garde le
sien. Les liens M3U ajoutés en mode « Lien » sont stockés en JSON dans le conteneur de l'app,
pas dans le trousseau.
