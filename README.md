# Antenne

Lecteur IPTV pour Mac et iPhone (SwiftUI, une seule cible multiplateforme).

- Playlists M3U / M3U8 par lien (actualisables) ou par fichier importé
- Chaînes avec logos, filtre par groupe, recherche, favoris
- Lecture avec le lecteur d'Apple (AVKit) : plein écran, Picture in Picture, AirPlay
- `#EXTVLCOPT:http-user-agent` respecté ; les flux `.ts` sont retentés en `.m3u8` (Xtream)

## Structure

- `Antenne/` : l'app (vues, lecteur)
- `AntenneCore/` : paquet Swift testable (parseur M3U, stockage, URL de flux)
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

Les liens de playlist (qui contiennent souvent identifiant et mot de passe) sont stockés en
JSON dans le conteneur de l'app, pas dans le trousseau.
