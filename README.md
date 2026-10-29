# Antenne

Lecteur IPTV pour Mac et iPhone (SwiftUI, une seule cible multiplateforme). L'app ne fournit
aucune chaîne : elle lit l'abonnement IPTV ou les playlists M3U que vous lui donnez.

- Comptes Xtream Codes (serveur, utilisateur, mot de passe) : Direct, Films et Séries par
  catégorie via `player_api.php`, chargés à l'ouverture et gardés en cache ; fiche série avec
  saisons et épisodes. Mot de passe dans le trousseau.
- Playlists M3U / M3U8 par lien (actualisables) ou par fichier importé
- Chaînes avec logos, filtre par groupe, recherche, favoris
- Lecture avec le lecteur d'Apple (AVKit) : plein écran, Picture in Picture, AirPlay ;
  VLCKit prend le relais pour ce qu'il ne lit pas (MKV, AVI, RTMP…), d'emblée pour ces formats
  ou après un échec du lecteur d'Apple
- Reprise de lecture des films et épisodes (« Reprendre au début » possible), progression et
  « Vu » dans les listes
- Guide des programmes des comptes Xtream : émission en cours dans les listes, guide détaillé
  sous la vidéo
- Synchronisation iCloud des playlists, favoris et positions de lecture entre appareils d'un
  même identifiant Apple ; mot de passe dans le trousseau iCloud
- `#EXTVLCOPT:http-user-agent` respecté ; les flux `.ts` sont retentés en `.m3u8` (Xtream)

## Structure

- `Antenne/` : l'app (vues, lecteur)
- `AntenneCore/` : paquet Swift testable (parseur M3U, client Xtream, stockage, URL de flux)
- `scripts/diagnostic-flux.sh` : état d'un compte Xtream et test d'un échantillon de flux avec ffprobe
- `Config/` : Info.plist (ATS ouvert pour les flux http) et entitlements macOS

## Lancer

Après un clone, récupérer VLCKit une fois (≈ 350 Mo depuis download.videolan.org, empreintes
vérifiées, rangé dans `Vendor/` hors de git) :

```bash
bash scripts/fetch-vlckit.sh
```

Puis ouvrir `Antenne.xcodeproj`, choisir « My Mac » ou l'iPhone branché, puis Run.

### Compiler avec son propre compte Apple

Le projet est signé avec l'équipe de son auteur (`GF98TAKX7X`). Pour l'installer chez vous
(Xcode 26, macOS 14 ou iOS 17 minimum) :

1. Dans Xcode, cible **Antenne** → **Signing & Capabilities** : choisir votre équipe
   (un compte Apple gratuit suffit pour l'iPhone, avec une installation valable 7 jours).
2. Remplacer l'identifiant `ci.novae.antenne` par le vôtre, par exemple `com.votrenom.antenne` :
   il est déjà réservé à l'équipe de l'auteur.
3. La synchronisation iCloud demande un compte Apple Developer payant. Sans lui, retirer la
   capacité **iCloud** (et, sur Mac, l'entrée `keychain-access-groups` de
   `Config/Antenne-macOS.entitlements`) : l'app fonctionne alors sans synchronisation.

Tests du cœur :

```bash
cd AntenneCore && swift test
```

## Limites connues

Lus par VLC, les flux n'ont ni Picture in Picture ni AirPlay, et les commandes sont réduites
(lecture/pause, position). VLCKit 3.7.3 pèse l'essentiel de l'app iPhone : 36 Mo installée
une fois retirées les tranches 32 bits, 96 Mo sans cela.

Pour un compte Xtream, la recherche porte sur les noms de catégories et les titres des
catégories déjà ouvertes : l'API ne permet pas de chercher dans tout le catalogue sans le
télécharger (plus de 500 000 entrées chez certains fournisseurs).

Les liens de flux Xtream contiennent identifiant et mot de passe : le cache des réponses n'en
contient pas (les liens sont reconstruits à la volée), mais une chaîne mise en favori garde le
sien. Les liens M3U ajoutés en mode « Lien » sont stockés en JSON dans le conteneur de l'app,
pas dans le trousseau.
