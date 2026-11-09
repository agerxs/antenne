# video_player_android 2.9.5, corrigé pour Antenne

Copie du paquet publié sur pub.dev (licence BSD, voir LICENSE), utilisée via `dependency_overrides`
dans `antenne_android/pubspec.yaml`. Dossiers `example/`, `test/` et `pigeons/` (sources de génération) retirés.

Seule modification : `android/src/main/java/io/flutter/plugins/videoplayer/platformview/PlatformViewExoPlayerEventListener.java`.
En affichage `VideoViewType.platformView`, `sendInitialized()` exigeait un format d'image
(`Objects.requireNonNull`) : un flux sans piste d'image décodable faisait planter l'app. Il annonce
désormais une image de 0 × 0, qu'Antenne traite comme un échec (bascule sur mpv).

Pour mettre à jour : recopier la nouvelle version du paquet et réappliquer ce correctif, ou retirer
l'override si le paquet officiel l'a corrigé.
