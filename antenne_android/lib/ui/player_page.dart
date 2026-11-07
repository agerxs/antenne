import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/xtream.dart';
import 'device.dart';
import 'library_scope.dart';
import 'playback.dart';
import 'widgets.dart';

/// Lecture d'une chaîne, d'un film ou d'un épisode : ExoPlayer d'abord, mpv s'il échoue.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.channel});
  final Channel channel;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Library _library = LibraryScope.read(context);
  // Le message de reprise vit au niveau de l'app : il faut l'effacer en quittant le lecteur.
  late ScaffoldMessengerState _messenger;
  Playback? _playback;
  var _loading = true;
  String? _failure;
  Timer? _progressTimer;
  Future<XtreamClient?>? _guideClient;
  var _fullscreen = false;
  var _screenKeptOn = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Sur un téléviseur, la vidéo occupe tout l'écran d'emblée.
      if (isTelevision) _setFullscreen(true);
      final channel = widget.channel;
      if (channel.isLive) {
        final client = _library.xtreamClientForChannel(channel);
        setState(() {
          _guideClient = client;
        });
      }
      _start(resume: _library.progress(channel)?.resumePosition);
    });
  }

  Future<void> _start({double? resume}) async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final start = resume == null ? null : Duration(milliseconds: (resume * 1000).round());
    Object? lastError;
    for (final engine in <Playback Function()>[ExoPlayback.new, MpvPlayback.new]) {
      final playback = engine();
      try {
        await playback.open(widget.channel, start: start);
        if (!mounted) return playback.dispose();
        setState(() {
          _playback = playback;
          _loading = false;
        });
        playback.addListener(_syncScreen);
        _syncScreen();
        break;
      } catch (error) {
        lastError = error;
        playback.dispose();
      }
    }
    if (!mounted) return;
    if (_playback == null) {
      setState(() {
        _loading = false;
        _failure = '$lastError';
      });
      return;
    }
    // Position notée régulièrement : la reprise marche même après une fermeture brutale.
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) => _recordProgress());
    if (resume != null) {
      _messenger.showSnackBar(SnackBar(
        content: Text('Reprise à ${timecode(resume)}'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: 'Recommencer', onPressed: () => _playback?.seek(Duration.zero)),
      ));
    }
  }

  /// L'écran reste allumé tant que la vidéo joue ; en pause, il retrouve sa mise en veille normale.
  void _syncScreen() {
    final playing = _playback?.playing ?? false;
    if (playing == _screenKeptOn) return;
    _screenKeptOn = playing;
    keepScreenOn(playing);
  }

  Future<void> _retry() async {
    _progressTimer?.cancel();
    _playback?.dispose();
    _playback = null;
    await _start();
  }

  void _recordProgress() {
    final playback = _playback;
    if (playback == null || widget.channel.isLive) return;
    _library.recordProgress(
      widget.channel,
      playback.position.inMilliseconds / 1000,
      playback.duration.inMilliseconds / 1000,
    );
  }

  Future<void> _setFullscreen(bool fullscreen) async {
    setState(() => _fullscreen = fullscreen);
    if (fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  @override
  void dispose() {
    _messenger.hideCurrentSnackBar();
    _recordProgress();
    _progressTimer?.cancel();
    _playback?.dispose();
    if (_screenKeptOn) keepScreenOn(false);
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final isFavorite = library.isFavorite(widget.channel);
    final screen = _Screen(
      playback: _playback,
      loading: _loading,
      failure: _failure,
      live: widget.channel.isLive,
      fullscreen: _fullscreen,
      favorite: isFavorite,
      onRetry: _retry,
      onFullscreen: () => _setFullscreen(!_fullscreen),
      onFavorite: () => toggleFavorite(context, widget.channel),
    );
    return PopScope(
      // Le retour quitte d'abord le plein écran, sauf sur un téléviseur où il n'y a que lui.
      canPop: !_fullscreen || isTelevision,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : null,
        appBar: _fullscreen
            ? null
            : AppBar(
                title: Text(widget.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: [
                  IconButton(
                    tooltip: isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
                    icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                    onPressed: () => library.toggleFavorite(widget.channel),
                  ),
                ],
              ),
        body: _fullscreen
            ? screen
            : Column(children: [
                AspectRatio(aspectRatio: 16 / 9, child: screen),
                Expanded(
                  child: _guideClient == null
                      ? _Details(channel: widget.channel)
                      : FutureBuilder<XtreamClient?>(
                          future: _guideClient,
                          builder: (context, snapshot) => snapshot.data == null
                              ? _Details(channel: widget.channel)
                              : GuidePanel(channel: widget.channel, client: snapshot.data!),
                        ),
                ),
              ]),
      ),
    );
  }
}

/// La vidéo et ses commandes, identiques quel que soit le moteur.
class _Screen extends StatefulWidget {
  const _Screen({
    required this.playback,
    required this.loading,
    required this.failure,
    required this.live,
    required this.fullscreen,
    required this.favorite,
    required this.onRetry,
    required this.onFullscreen,
    required this.onFavorite,
  });

  final Playback? playback;
  final bool loading;
  final String? failure;
  final bool live;
  final bool fullscreen;
  final bool favorite;
  final VoidCallback onRetry;
  final VoidCallback onFullscreen;
  final VoidCallback onFavorite;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  var _controlsVisible = true;
  Timer? _hide;
  double? _scrubbing;
  Timer? _seekSettle;
  var _okDown = false;
  var _okHeld = false;

  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _seekSettle?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hide?.cancel();
    // Les commandes s'effacent seules pendant la lecture.
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && (widget.playback?.playing ?? false) && _scrubbing == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  /// Télécommande et clavier : OK bref lit ou met en pause, OK maintenu met en favori,
  /// gauche/droite reculent ou avancent de 10 s, haut/bas montrent les commandes.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final playback = widget.playback;
    if (_okKeys.contains(key)) {
      switch (event) {
        case KeyDownEvent():
          _okDown = true;
          _okHeld = false;
        case KeyRepeatEvent():
          if (_okDown && !_okHeld) {
            _okHeld = true;
            widget.onFavorite();
            _showControls();
          }
        case KeyUpEvent():
          // Le relâchement de l'appui qui a ouvert le lecteur arrive ici : il ne compte pas.
          if (_okDown && !_okHeld) {
            if (widget.failure != null || playback?.error != null) {
              widget.onRetry();
            } else {
              playback?.togglePlay();
              _showControls();
            }
          }
          _okDown = false;
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        (key == LogicalKeyboardKey.mediaPlay && !(playback?.playing ?? true)) ||
        (key == LogicalKeyboardKey.mediaPause && (playback?.playing ?? false))) {
      if (event is KeyDownEvent) playback?.togglePlay();
      _showControls();
      return KeyEventResult.handled;
    }
    final step = switch (key) {
      LogicalKeyboardKey.arrowLeft => -10,
      LogicalKeyboardKey.arrowRight => 10,
      LogicalKeyboardKey.mediaRewind => -30,
      LogicalKeyboardKey.mediaFastForward => 30,
      _ => null,
    };
    if (step != null) {
      if (playback != null) _seekBy(playback, step);
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      _showControls();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Les appuis répétés s'additionnent : la barre suit la position visée, pas celle déjà atteinte.
  void _seekBy(Playback playback, int seconds) {
    final duration = playback.duration.inMilliseconds;
    if (widget.live || duration <= 0) return;
    final from = _scrubbing ?? playback.position.inMilliseconds.toDouble();
    final target = (from + seconds * 1000).clamp(0, duration).toDouble();
    setState(() => _scrubbing = target);
    playback.seek(Duration(milliseconds: target.round()));
    _seekSettle?.cancel();
    _seekSettle = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _scrubbing = null);
      _scheduleHide();
    });
  }

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, onKeyEvent: _onKey, child: _video(context));

  Widget _video(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playback = widget.playback;
    final failure = widget.failure ?? playback?.error;
    return ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        if (playback != null) playback.view(),
        GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggleControls),
        if (failure != null)
          Container(
            color: Colors.black87,
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.warning_amber_rounded, color: scheme.onSurfaceVariant, size: 28),
              const SizedBox(height: 8),
              const Text('Lecture impossible', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Le flux ne répond pas, ou ni ExoPlayer ni mpv ne savent le lire.',
                  textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: widget.onRetry, child: const Text('Réessayer')),
            ]),
          )
        else if (playback == null)
          const Center(child: CircularProgressIndicator())
        else
          ListenableBuilder(
            listenable: playback,
            builder: (context, _) => Stack(fit: StackFit.expand, children: [
              if (playback.buffering && !playback.playing) const Center(child: CircularProgressIndicator()),
              if (_controlsVisible) Positioned(left: 0, right: 0, bottom: 0, child: _bar(playback)),
            ]),
          ),
      ]),
    );
  }

  Widget _bar(Playback playback) {
    final duration = playback.duration;
    final seekable = !widget.live && duration > Duration.zero;
    final position = _scrubbing ?? playback.position.inMilliseconds.toDouble();
    const style = TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
      ),
      child: Row(children: [
        IconButton(
          color: Colors.white,
          tooltip: playback.playing ? 'Pause' : 'Lecture',
          icon: Icon(playback.playing ? Icons.pause : Icons.play_arrow),
          onPressed: () {
            playback.togglePlay();
            _scheduleHide();
          },
        ),
        if (seekable) ...[
          Text(timecode(position / 1000), style: style),
          Expanded(
            child: Slider(
              value: position.clamp(0, duration.inMilliseconds.toDouble()),
              max: duration.inMilliseconds.toDouble(),
              onChanged: (value) => setState(() => _scrubbing = value),
              onChangeEnd: (value) {
                playback.seek(Duration(milliseconds: value.round()));
                setState(() => _scrubbing = null);
                _scheduleHide();
              },
            ),
          ),
          Text(timecode(duration.inMilliseconds / 1000), style: style),
        ] else ...[
          const SizedBox(width: 4),
          const Text('DIRECT', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.8)),
          const Spacer(),
        ],
        if (playback.badge case final badge?)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
            child: Text(badge, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
        if (isTelevision) ...[
          const SizedBox(width: 12),
          Icon(widget.favorite ? Icons.star : Icons.star_border,
              size: 18, color: widget.favorite ? const Color(0xFFF7C948) : Colors.white70),
          const SizedBox(width: 6),
          const Text('Maintenir OK : favori', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 12),
        ] else
          IconButton(
            color: Colors.white,
            tooltip: widget.fullscreen ? 'Quitter le plein écran' : 'Plein écran',
            icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            onPressed: widget.onFullscreen,
          ),
      ]),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) => ListView(children: [
        ListTile(
          title: Text(channel.name, style: Theme.of(context).textTheme.titleMedium),
          subtitle: channel.group == null ? null : Text(channel.group!),
        ),
      ]);
}

/// Guide des programmes sous la vidéo d'une chaîne en direct.
class GuidePanel extends StatefulWidget {
  const GuidePanel({super.key, required this.channel, required this.client});
  final Channel channel;
  final XtreamClient client;

  @override
  State<GuidePanel> createState() => _GuidePanelState();
}

class _GuidePanelState extends State<GuidePanel> {
  List<EpgProgramme>? _programmes;
  Object? _error;
  Timer? _refresh;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    // Le guide se met à jour tant que la chaîne reste affichée.
    _refresh = Timer.periodic(const Duration(minutes: 10), (_) => _load());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  Future<void> _load() async {
    try {
      final programmes = await widget.client.guide(widget.channel, limit: 8);
      if (mounted) setState(() => _programmes = programmes);
    } catch (error) {
      if (mounted && _programmes == null) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final upcoming = _programmes?.where((p) => p.end.isAfter(now)).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Programme', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
      ),
      if (_error != null && upcoming == null)
        ListTile(title: Text('Guide indisponible pour le moment.', style: TextStyle(color: scheme.onSurfaceVariant)))
      else if (upcoming == null)
        const LoadingRow(text: 'Chargement du guide…')
      else if (upcoming.isEmpty)
        ListTile(title: Text('Aucun programme annoncé pour cette chaîne.', style: TextStyle(color: scheme.onSurfaceVariant)))
      else
        for (final programme in upcoming) _ProgrammeTile(programme: programme, now: now),
    ]);
  }
}

class _ProgrammeTile extends StatelessWidget {
  const _ProgrammeTile({required this.programme, required this.now});
  final EpgProgramme programme;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onAir = programme.isOnAir(now);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(onAir ? 'En ce moment' : clock(programme.start),
              style: TextStyle(fontSize: 12, fontWeight: onAir ? FontWeight.w600 : FontWeight.normal, color: onAir ? scheme.primary : scheme.onSurfaceVariant)),
          const Spacer(),
          Text('${clock(programme.start)} – ${clock(programme.end)}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text(programme.title, style: onAir ? Theme.of(context).textTheme.titleMedium : null),
        if (onAir)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: programme.progress(now), minHeight: 3, backgroundColor: scheme.surfaceContainerHigh),
            ),
          ),
        if (programme.summary case final summary?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(summary, maxLines: onAir ? 4 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}
