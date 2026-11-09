import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/xtream.dart';
import 'channel_groups.dart';
import 'device.dart';
import 'diagnostics.dart';
import 'library_scope.dart';
import 'playback.dart';
import 'widgets.dart';

/// Lecture d'une chaîne, d'un film ou d'un épisode : ExoPlayer d'abord, mpv s'il échoue.
/// Ouvert depuis une liste, il garde ses voisines : on zappe et on change de catégorie sans en sortir.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.channel, this.groups, this.group = 0});
  final Channel channel;
  final ChannelGroups? groups;
  final int group;

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
  late Channel _channel = widget.channel;
  late int _group = widget.group;
  var _panelOpen = false;
  final _screenFocus = FocusNode(debugLabel: 'lecteur');

  /// Rang de la dernière ouverture : un zap rapide abandonne celle d'avant.
  var _attempt = 0;

  bool get _canZap => widget.groups != null;

  /// Moteurs, dans l'ordre d'essai par défaut. Selon la puce graphique, l'un peut rester noir quand
  /// un autre affiche l'image : on en change avec Bas, et le choix vaut pour la suite de la session.
  /// La texture d'abord : elle marche sur la plupart des appareils. La surface sauve les box à puce
  /// graphique ancienne, mpv les formats qu'Android ne décode pas.
  static final _engines = <Playback Function()>[ExoPlayback.texture, ExoPlayback.surface, MpvPlayback.new];
  var _engineIndex = 0;

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
      _open(_channel);
    });
  }

  void _open(Channel channel) {
    setState(() {
      _channel = channel;
      _guideClient = channel.isLive ? _library.xtreamClientForChannel(channel) : null;
    });
    _start(resume: _library.progress(channel)?.resumePosition);
  }

  /// Passe à une autre chaîne sans quitter le lecteur.
  void _zap(Channel channel, int group) {
    _closePanel();
    _group = group;
    if (channel == _channel && _playback != null && _failure == null) return;
    _messenger.hideCurrentSnackBar();
    _stop();
    _open(channel);
  }

  /// Chaîne précédente ou suivante de la catégorie (CH+ / CH− de la télécommande).
  Future<void> _zapBy(int step) async {
    final groups = widget.groups;
    if (groups == null) return;
    final channels = await groups.channels(_group).catchError((Object _) => <Channel>[]);
    if (!mounted || channels.isEmpty) return;
    final index = channels.indexOf(_channel);
    _zap(channels[(index + step) % channels.length], _group);
  }

  void _openPanel() {
    if (_canZap) setState(() => _panelOpen = true);
  }

  void _closePanel() {
    if (!_panelOpen) return;
    setState(() => _panelOpen = false);
    _screenFocus.requestFocus();
  }

  /// Arrête la lecture en cours (position notée pour un film).
  void _stop() {
    _attempt++;
    _recordProgress();
    _progressTimer?.cancel();
    final playback = _playback;
    playback?.removeListener(_syncScreen);
    playback?.dispose();
    setState(() {
      _playback = null;
      _failure = null;
    });
  }

  Future<void> _start({double? resume}) async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final start = resume == null ? null : Duration(milliseconds: (resume * 1000).round());
    Object? lastError;
    final channel = _channel;
    final attempt = ++_attempt;
    for (var i = 0; i < _engines.length; i++) {
      final index = (EnginePreference.index + i) % _engines.length;
      final playback = _engines[index]();
      try {
        await playback.open(channel, start: start);
        final size = playback.videoSize;
        PlaybackLog.add('${channel.name} · ${streamFormat(channel)} · ${playback.engineName} : '
            'image ${size.width.round()}×${size.height.round()}');
        if (!mounted || attempt != _attempt) return playback.dispose();
        _engineIndex = index;
        setState(() {
          _playback = playback;
          _loading = false;
        });
        playback.addListener(_syncScreen);
        _syncScreen();
        break;
      } catch (error) {
        lastError = error;
        PlaybackLog.add('${channel.name} · ${streamFormat(channel)} · ${playback.engineName} : échec, ${hideLinks(error)}');
        playback.dispose();
        if (attempt != _attempt) return;
      }
    }
    if (!mounted || attempt != _attempt) return;
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

  /// Relance la lecture avec l'autre moteur, à la même position pour un film.
  Future<void> _switchEngine() async {
    final playback = _playback;
    if (playback == null) return;
    EnginePreference.save((_engineIndex + 1) % _engines.length);
    PlaybackLog.add('Changement de lecteur à la main (${playback.engineName} → suivant)');
    final position = _channel.isLive ? null : playback.position.inMilliseconds / 1000;
    _progressTimer?.cancel();
    playback.removeListener(_syncScreen);
    playback.dispose();
    setState(() => _playback = null);
    await _start(resume: position);
    if (mounted && _playback != null) {
      _messenger.showSnackBar(SnackBar(
        content: Text('Lecteur : ${_playback!.engineName}. Image noire ? Bas pour changer encore.'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _retry() async {
    _progressTimer?.cancel();
    _playback?.dispose();
    _playback = null;
    await _start();
  }

  void _recordProgress() {
    final playback = _playback;
    if (playback == null || _channel.isLive) return;
    _library.recordProgress(
      _channel,
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
    _screenFocus.dispose();
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
    final channel = _channel;
    final isFavorite = library.isFavorite(channel);
    final screen = _Screen(
      focusNode: _screenFocus,
      title: channel.name,
      playback: _playback,
      loading: _loading,
      failure: _failure,
      live: channel.isLive,
      fullscreen: _fullscreen,
      favorite: isFavorite,
      canZap: _canZap,
      panelOpen: _panelOpen,
      onRetry: _retry,
      onFullscreen: () => _setFullscreen(!_fullscreen),
      onFavorite: () => toggleFavorite(context, channel),
      onSwitchEngine: _switchEngine,
      onOpenPanel: _openPanel,
      onZapBy: _zapBy,
    );
    return PopScope(
      // Le retour ferme d'abord la liste des chaînes, puis quitte le plein écran,
      // sauf sur un téléviseur où il n'y a que lui.
      canPop: !_panelOpen && (!_fullscreen || isTelevision),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_panelOpen) {
          _closePanel();
        } else {
          _setFullscreen(false);
        }
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : null,
        appBar: _fullscreen
            ? null
            : AppBar(
                title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: [
                  if (_canZap)
                    IconButton(tooltip: 'Chaînes', icon: const Icon(Icons.format_list_bulleted), onPressed: _openPanel),
                  IconButton(
                    tooltip: isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
                    icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                    onPressed: () => library.toggleFavorite(channel),
                  ),
                ],
              ),
        body: Stack(fit: StackFit.expand, children: [
          if (_fullscreen)
            screen
          else
            Column(children: [
              // Téléphone en paysage : la vidéo laisse de la place au guide au lieu de déborder.
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
                child: AspectRatio(aspectRatio: 16 / 9, child: screen),
              ),
              Expanded(
                child: _guideClient == null
                    ? _Details(channel: channel)
                    : FutureBuilder<XtreamClient?>(
                        key: ValueKey(channel.url),
                        future: _guideClient,
                        builder: (context, snapshot) => snapshot.data == null
                            ? _Details(channel: channel)
                            : GuidePanel(key: ValueKey(channel.url), channel: channel, client: snapshot.data!),
                      ),
              ),
            ]),
          if (_panelOpen && widget.groups != null) ...[
            // Un appui à côté de la liste la ferme.
            GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closePanel),
            _ChannelPanel(
              groups: widget.groups!,
              group: _group,
              current: channel,
              engineName: _playback?.engineName,
              onPick: _zap,
              onSwitchEngine: () {
                _closePanel();
                _switchEngine();
              },
            ),
          ],
        ]),
      ),
    );
  }
}

/// La vidéo et ses commandes, identiques quel que soit le moteur.
class _Screen extends StatefulWidget {
  const _Screen({
    required this.focusNode,
    required this.title,
    required this.canZap,
    required this.panelOpen,
    required this.onOpenPanel,
    required this.onZapBy,
    required this.playback,
    required this.loading,
    required this.failure,
    required this.live,
    required this.fullscreen,
    required this.favorite,
    required this.onRetry,
    required this.onFullscreen,
    required this.onFavorite,
    required this.onSwitchEngine,
  });

  final FocusNode focusNode;
  final String title;

  /// Ouvert depuis une liste : OK et Bas ouvrent la liste des chaînes, CH+ / CH− zappent.
  final bool canZap;
  final bool panelOpen;
  final VoidCallback onOpenPanel;
  final void Function(int step) onZapBy;
  final Playback? playback;
  final bool loading;
  final String? failure;
  final bool live;
  final bool fullscreen;
  final bool favorite;
  final VoidCallback onRetry;
  final VoidCallback onFullscreen;
  final VoidCallback onFavorite;
  final VoidCallback onSwitchEngine;

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
  void didUpdateWidget(_Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Après un zap, le nom de la nouvelle chaîne s'affiche un moment.
    if (oldWidget.title != widget.title) _showControls();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _seekSettle?.cancel();
    super.dispose();
  }

  /// Un film se met en pause avec OK ; une chaîne en direct ouvre la liste des chaînes.
  bool get _seekable => !widget.live && (widget.playback?.duration ?? Duration.zero) > Duration.zero;

  void _scheduleHide() {
    _hide?.cancel();
    // Les commandes s'effacent seules pendant la lecture.
    // Sur un téléviseur, les commandes restent plus longtemps : elles indiquent comment changer de lecteur.
    _hide = Timer(Duration(seconds: isTelevision ? 8 : 4), () {
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

  /// Télécommande et clavier : OK bref lit ou met en pause (ouvre la liste des chaînes en direct),
  /// OK maintenu met en favori, gauche/droite reculent ou avancent de 10 s, bas ouvre la liste des
  /// chaînes (ou change de lecteur hors d'une liste), CH+ / CH− zappent, Menu change de lecteur.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // La liste des chaînes ouverte gère elle-même ses touches.
    if (widget.panelOpen) return KeyEventResult.ignored;
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
            if (widget.canZap && !_seekable) {
              widget.onOpenPanel();
            } else if (widget.failure != null || playback?.error != null) {
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
    final zap = switch (key) {
      LogicalKeyboardKey.channelUp || LogicalKeyboardKey.pageUp => -1,
      LogicalKeyboardKey.channelDown || LogicalKeyboardKey.pageDown => 1,
      _ => null,
    };
    if (zap != null) {
      if (event is KeyDownEvent) widget.onZapBy(zap);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      if (event is KeyDownEvent && playback != null) widget.onSwitchEngine();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.canZap) {
      if (event is KeyDownEvent) widget.onOpenPanel();
      return KeyEventResult.handled;
    }
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
    // Hors d'une liste, Bas change de moteur. À la télécommande, à tout moment : sur une image noire,
    // on ne voit pas toujours les commandes. Au toucher, seulement quand elles sont affichées.
    if (key == LogicalKeyboardKey.arrowDown && (_controlsVisible || isTelevision) && event is KeyDownEvent && playback != null) {
      widget.onSwitchEngine();
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
  Widget build(BuildContext context) =>
      Focus(focusNode: widget.focusNode, autofocus: true, onKeyEvent: _onKey, child: _video(context));

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
              const SizedBox(height: 8),
              // Détail du lecteur, pour comprendre la panne. Les liens sont masqués : ceux d'un
              // compte Xtream contiennent l'identifiant et le mot de passe.
              Text(failure.replaceAll(RegExp(r'\w+://\S+'), '[lien]'),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 11)),
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
          if (widget.fullscreen) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ] else
            const Spacer(),
        ],
        // Moteur en cours : un appui (ou Bas à la télécommande) passe à l'autre.
        GestureDetector(
          onTap: widget.onSwitchEngine,
          child: Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.swap_horiz, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(isTelevision && !widget.canZap ? '${playback.engineName} · Bas : changer' : playback.engineName,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
        if (isTelevision) ...[
          if (widget.canZap) ...[
            const SizedBox(width: 12),
            const Icon(Icons.format_list_bulleted, size: 18, color: Colors.white70),
            const SizedBox(width: 6),
            Text(_seekable ? 'Bas : liste' : 'OK : chaînes', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
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

/// Liste des chaînes par-dessus la vidéo : Haut/Bas pour choisir, OK pour zapper,
/// Gauche/Droite pour changer de catégorie, Retour pour fermer.
class _ChannelPanel extends StatefulWidget {
  const _ChannelPanel({
    required this.groups,
    required this.group,
    required this.current,
    required this.engineName,
    required this.onPick,
    required this.onSwitchEngine,
  });

  final ChannelGroups groups;
  final int group;
  final Channel current;
  final String? engineName;
  final void Function(Channel channel, int group) onPick;
  final VoidCallback onSwitchEngine;

  @override
  State<_ChannelPanel> createState() => _ChannelPanelState();
}

class _ChannelPanelState extends State<_ChannelPanel> {
  late var _group = widget.group;

  void _changeGroup(int step) {
    final count = widget.groups.names.length;
    if (count > 1) setState(() => _group = (_group + step) % count);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => null,
    };
    if (step == null) return KeyEventResult.ignored;
    _changeGroup(step);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final several = widget.groups.names.length > 1;
    return Align(
      alignment: Alignment.centerLeft,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Material(
          color: const Color(0xF20C1322),
          child: SizedBox(
            width: screenWidth < 600 ? screenWidth * 0.86 : (screenWidth * 0.4).clamp(360, 520),
            child: SafeArea(
              right: false,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Row(children: [
                    if (several)
                      IconButton(
                        tooltip: 'Catégorie précédente',
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () => _changeGroup(-1),
                      ),
                    Expanded(
                      child: Text(widget.groups.names[_group],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: several ? TextAlign.center : TextAlign.start,
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    if (several)
                      IconButton(
                        tooltip: 'Catégorie suivante',
                        icon: const Icon(Icons.chevron_right),
                        onPressed: () => _changeGroup(1),
                      ),
                  ]),
                ),
                if (isTelevision)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      several ? 'Gauche / Droite : catégorie · Retour : fermer' : 'Retour : fermer',
                      textAlign: several ? TextAlign.center : TextAlign.start,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (isTelevision && widget.engineName != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.swap_horiz, size: 20),
                    title: Text('Lecteur : ${widget.engineName}'),
                    subtitle: const Text('Image noire ? OK pour en essayer un autre'),
                    onTap: widget.onSwitchEngine,
                  ),
                const Divider(height: 1),
                Expanded(
                  child: FutureBuilder<List<Channel>>(
                    key: ValueKey(_group),
                    future: widget.groups.channels(_group),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return ListView(children: [FailureRow(message: '${snapshot.error}', onRetry: () => setState(() {}))]);
                      }
                      final channels = snapshot.data;
                      if (channels == null) return ListView(children: const [LoadingRow(text: 'Chargement…')]);
                      if (channels.isEmpty) return ListView(children: const [ListTile(title: Text('Catégorie vide.'))]);
                      return _ChannelColumn(
                        key: ValueKey(_group),
                        channels: channels,
                        current: widget.current,
                        onPick: (channel) => widget.onPick(channel, _group),
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Les chaînes d'une catégorie, la chaîne en cours sélectionnée et visible dès l'ouverture.
class _ChannelColumn extends StatefulWidget {
  const _ChannelColumn({super.key, required this.channels, required this.current, required this.onPick});
  final List<Channel> channels;
  final Channel current;
  final ValueChanged<Channel> onPick;

  @override
  State<_ChannelColumn> createState() => _ChannelColumnState();
}

class _ChannelColumnState extends State<_ChannelColumn> {
  static const _rowHeight = 60.0;
  late final int _focused = widget.channels.indexOf(widget.current).clamp(0, widget.channels.length - 1);
  late int _position = _focused;
  late final _scroll = ScrollController(initialScrollOffset: (_focused - 3).clamp(0, 1 << 20) * _rowHeight);
  final _focusedNode = FocusNode(debugLabel: 'chaîne en cours');

  @override
  void initState() {
    super.initState();
    // autofocus ne suffit pas : la vidéo garde le focus tant qu'on ne le lui retire pas.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusedNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focusedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 20, 2),
        child: Align(
          alignment: Alignment.centerRight,
          child: ListHeaderCount(position: _position, count: widget.channels.length),
        ),
      ),
      Expanded(
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          thickness: 6,
          radius: const Radius.circular(3),
          child: _list(scheme),
        ),
      ),
    ]);
  }

  Widget _list(ColorScheme scheme) {
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowHeight,
      padding: const EdgeInsets.only(right: 10),
      itemCount: widget.channels.length,
      itemBuilder: (context, index) {
        final channel = widget.channels[index];
        final playing = channel == widget.current;
        return ListTile(
          onFocusChange: (focused) {
            if (focused && _position != index) setState(() => _position = index);
          },
          focusNode: index == _focused ? _focusedNode : null,
          leading: ChannelLogo(url: channel.logoUrl, name: channel.name, width: 48, height: 32),
          title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: playing ? Icon(Icons.play_arrow, size: 18, color: scheme.primary) : null,
          selected: playing,
          selectedColor: scheme.primary,
          onTap: () => widget.onPick(channel),
        );
      },
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
