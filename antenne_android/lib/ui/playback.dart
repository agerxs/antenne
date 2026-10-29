import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/xtream.dart';

/// Un moteur de lecture, vu par l'écran : la vidéo, son état et deux commandes.
abstract class Playback extends ChangeNotifier {
  /// Nom affiché quand ce n'est pas le moteur principal.
  String? get badge;

  Widget view();
  bool get playing;
  bool get buffering;
  Duration get position;

  /// Zéro pour le direct, ou tant que la durée est inconnue.
  Duration get duration;

  Future<void> open(Channel channel, {Duration? start});
  Future<void> togglePlay();
  Future<void> seek(Duration position);

  /// Message d'erreur survenu pendant la lecture, après un démarrage réussi.
  String? get error;
}

/// ExoPlayer (Media3), via le plugin officiel : décodeurs matériels du téléphone,
/// HLS, MPEG-TS, MP4, MKV, AVI. C'est le moteur de TiviMate et d'IPTV Smarters.
class ExoPlayback extends Playback {
  VideoPlayerController? _controller;
  String? _error;

  @override
  String? get badge => null;

  @override
  Widget view() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return const SizedBox.expand();
    return Center(
      child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)),
    );
  }

  VideoPlayerValue get _value => _controller?.value ?? const VideoPlayerValue.uninitialized();

  @override
  bool get playing => _value.isPlaying;
  @override
  bool get buffering => _value.isBuffering || !_value.isInitialized;
  @override
  Duration get position => _value.position;
  @override
  Duration get duration => _value.duration.isNegative ? Duration.zero : _value.duration;
  @override
  String? get error => _error;

  @override
  Future<void> open(Channel channel, {Duration? start}) async {
    final uri = Uri.parse(channel.url);
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: {'User-Agent': channel.userAgent ?? userAgent},
      formatHint: uri.path.toLowerCase().endsWith('.m3u8') ? VideoFormat.hls : null,
    );
    _controller = controller;
    // Un flux muet au-delà de ce délai est considéré comme illisible : le moteur de secours essaie.
    await controller.initialize().timeout(const Duration(seconds: 20));
    if (start != null) await controller.seekTo(start);
    await controller.play();
    controller.addListener(_changed);
    notifyListeners();
  }

  void _changed() {
    final value = _value;
    if (value.hasError && _error == null) _error = value.errorDescription ?? 'Erreur de lecture.';
    notifyListeners();
  }

  @override
  Future<void> togglePlay() async => playing ? _controller?.pause() : _controller?.play();

  @override
  Future<void> seek(Duration position) async => _controller?.seekTo(position);

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }
}

/// mpv (media_kit), en secours : décodage logiciel de presque tous les formats et codecs.
class MpvPlayback extends Playback {
  final _player = Player();
  late final _video = VideoController(_player);
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _error;

  @override
  String? get badge => 'mpv';

  @override
  Widget view() => Video(controller: _video, controls: NoVideoControls, fill: Colors.black);

  @override
  bool get playing => _player.state.playing;
  @override
  bool get buffering => _player.state.buffering;
  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  String? get error => _error;

  @override
  Future<void> open(Channel channel, {Duration? start}) async {
    final ready = Completer<void>();
    _subscriptions.addAll([
      _player.stream.position.listen((_) => notifyListeners()),
      _player.stream.playing.listen((_) => notifyListeners()),
      _player.stream.buffering.listen((_) => notifyListeners()),
      _player.stream.duration.listen((_) => notifyListeners()),
      _player.stream.width.listen((width) {
        if (width != null && width > 0 && !ready.isCompleted) ready.complete();
      }),
      _player.stream.error.listen((message) {
        if (!ready.isCompleted) {
          ready.completeError(Exception(message));
        } else {
          _error = message;
          notifyListeners();
        }
      }),
    ]);
    await _player.open(Media(
      channel.url,
      httpHeaders: {'User-Agent': channel.userAgent ?? userAgent},
      start: start,
    ));
    await ready.future.timeout(const Duration(seconds: 20));
  }

  @override
  Future<void> togglePlay() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
