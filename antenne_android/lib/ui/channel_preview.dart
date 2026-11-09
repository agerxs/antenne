import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'device.dart';
import 'player_page.dart';
import 'playback.dart';

/// Aperçu de la chaîne sélectionnée dans une liste, comme TiviMate ou iMPlayer : la lecture démarre
/// quand la sélection s'arrête sur une chaîne, et OK la reprend telle quelle en plein écran.
/// Une seule lecture à la fois : un abonnement limité à un écran refuse la seconde.
class ChannelPreview extends ChangeNotifier {
  Channel? _channel;
  OpenedPlayback? _opened;
  String? _failure;
  Timer? _delay;
  var _attempt = 0;
  var _disposed = false;

  Channel? get channel => _channel;
  Playback? get playback => _opened?.playback;
  String? get failure => _failure;
  bool get loading => _channel != null && _opened == null && _failure == null;

  /// Les films et épisodes ne se prévisualisent pas : seulement le direct.
  static bool previewable(Channel channel) {
    if (channel.isLive) return true;
    final path = Uri.tryParse(channel.url)?.path.toLowerCase() ?? '';
    return !RegExp(r'\.(mp4|mkv|avi|mov|webm|m4v)$').hasMatch(path) && !path.contains('/movie/') && !path.contains('/series/');
  }

  /// La sélection s'est posée sur [channel] : son aperçu démarre après un court instant,
  /// pour ne pas ouvrir chaque chaîne qu'on traverse.
  void show(Channel channel) {
    if (channel == _channel || !previewable(channel)) return;
    stop();
    _channel = channel;
    notifyListeners();
    final attempt = _attempt;
    _delay = Timer(const Duration(milliseconds: 700), () => _open(channel, attempt));
  }

  Future<void> _open(Channel channel, int attempt) async {
    bool wanted() => !_disposed && attempt == _attempt;
    try {
      final opened = await openPlayback(channel, wanted: wanted);
      if (opened == null) return;
      _opened = opened;
    } catch (error) {
      if (!wanted()) return;
      _failure = '$error';
    }
    notifyListeners();
  }

  /// Arrête l'aperçu et rend sa lecture si c'est celle de [channel] (pour le plein écran).
  /// Dans tous les cas, plus rien ne joue ici ensuite.
  OpenedPlayback? take(Channel channel) {
    final opened = channel == _channel && _opened?.playback.error == null ? _opened : null;
    if (opened != null) _opened = null;
    stop();
    return opened;
  }

  void stop() {
    _attempt++;
    _delay?.cancel();
    _opened?.playback.dispose();
    final hadSomething = _channel != null;
    _opened = null;
    _channel = null;
    _failure = null;
    if (hadSomething && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }

  /// L'aperçu de la liste qui contient [context], s'il y en a un.
  static ChannelPreview? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ChannelPreviewScope>()?.preview;
}

/// Rend l'aperçu accessible aux lignes de la liste (sélection et ouverture).
class ChannelPreviewScope extends InheritedWidget {
  const ChannelPreviewScope({super.key, required this.preview, required super.child});
  final ChannelPreview preview;

  @override
  bool updateShouldNotify(ChannelPreviewScope oldWidget) => oldWidget.preview != preview;
}

/// Colonne de droite : la vidéo de l'aperçu, le nom de la chaîne et, en dessous, [details]
/// (le programme pour un compte Xtream).
class ChannelPreviewPane extends StatelessWidget {
  const ChannelPreviewPane({super.key, required this.preview, this.details});
  final ChannelPreview preview;
  final Widget Function(Channel channel)? details;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: preview,
      builder: (context, _) {
        final channel = preview.channel;
        final playback = preview.playback;
        return LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Écran bas (téléphone en paysage) : la vidéo laisse la place au nom de la chaîne.
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.62),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ColoredBox(
                    color: Colors.black,
                    child: channel == null
                        ? Center(
                            child: Text(
                              'Sélectionne une chaîne\npour la voir ici',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          )
                        : preview.failure != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Aperçu impossible.\nOK pour essayer en plein écran.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          )
                        : playback == null
                        ? const Center(child: CircularProgressIndicator())
                        : playback.view(),
                  ),
                ),
              ),
              if (channel != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (isTelevision)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                    child: Text('OK : plein écran', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                if (details != null)
                  Expanded(
                    child: KeyedSubtree(key: ValueKey(channel.url), child: details!(channel)),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
