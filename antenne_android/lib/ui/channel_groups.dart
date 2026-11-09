import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'device.dart';
import 'widgets.dart';

/// Les groupes d'une source de chaînes (catégories d'un compte Xtream, groupes d'une playlist M3U,
/// favoris), chacun chargé à la demande. Le lecteur s'en sert pour zapper et changer de catégorie
/// sans revenir à la liste.
class ChannelGroups {
  ChannelGroups({required this.names, required Future<List<Channel>> Function(int index) load}) : _load = load;

  /// Une liste déjà en mémoire : « Toutes les chaînes » en tête, puis ses groupes dans l'ordre d'apparition.
  /// Sans groupes, un seul, nommé [title].
  factory ChannelGroups.fromList(List<Channel> channels, {String title = 'Toutes les chaînes'}) {
    final groups = {for (final c in channels) if (c.group != null) c.group!}.toList();
    if (groups.length <= 1) return ChannelGroups(names: [title], load: (_) async => channels);
    return ChannelGroups(
      names: ['Toutes les chaînes', ...groups],
      load: (index) async => index == 0 ? channels : channels.where((c) => c.group == groups[index - 1]).toList(),
    );
  }

  final List<String> names;
  final Future<List<Channel>> Function(int index) _load;
  final _cache = <int, Future<List<Channel>>>{};

  /// Les chaînes d'un groupe. Un échec n'est pas gardé : le prochain appel réessaie.
  Future<List<Channel>> channels(int index) => _cache[index] ??= _load(index).catchError((Object error) {
        _cache.remove(index);
        throw error;
      });
}

/// À partir de quelle largeur la liste passe en deux colonnes (catégories à gauche, chaînes à droite).
bool wideLayout(BuildContext context) => isTelevision || MediaQuery.sizeOf(context).width >= 840;

/// Catégories à gauche, chaînes de la catégorie sélectionnée à droite : à la télécommande, on passe
/// d'une catégorie à l'autre sans revenir en arrière. La catégorie suit la sélection, Droite entre dans
/// ses chaînes, Gauche ou Retour en ressortent. Une barre et un compteur disent où l'on est dans la liste.
class GroupedChannelBrowser extends StatefulWidget {
  const GroupedChannelBrowser({super.key, required this.groups, required this.tile, this.query = ''});
  final ChannelGroups groups;

  /// La ligne d'une chaîne, avec le rang de sa catégorie (pour que le lecteur y retrouve ses voisines).
  final Widget Function(Channel channel, int group) tile;

  /// Recherche en cours, en minuscules : filtre les catégories par nom, et les chaînes de la catégorie ouverte.
  final String query;

  @override
  State<GroupedChannelBrowser> createState() => _GroupedChannelBrowserState();
}

class _GroupedChannelBrowserState extends State<GroupedChannelBrowser> {
  var _selected = 0;
  Timer? _follow;
  final _nodes = <int, FocusNode>{};
  final _channelsScroll = ScrollController();

  /// La sélection est dans les chaînes : Retour ramène aux catégories au lieu de quitter l'écran.
  var _inChannels = false;

  /// Rang de la chaîne sélectionnée (à partir de 0), pour le compteur « 12 / 240 ».
  int? _position;

  FocusNode _node(int index) => _nodes.putIfAbsent(index, () => FocusNode(debugLabel: 'catégorie $index'));

  @override
  void didUpdateWidget(GroupedChannelBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.groups, widget.groups)) _selected = 0;
  }

  @override
  void dispose() {
    _follow?.cancel();
    _channelsScroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _select(int index) {
    _follow?.cancel();
    if (index == _selected) return;
    setState(() {
      _selected = index;
      _position = null;
    });
    if (_channelsScroll.hasClients) _channelsScroll.jumpTo(0);
  }

  /// Retour sur la catégorie ouverte, pas sur sa voisine d'en face.
  bool _backToGroups() {
    final node = _node(_selected);
    if (node.context == null) return false;
    node.requestFocus();
    return true;
  }

  KeyEventResult _onChannelsKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    return _backToGroups() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final names = widget.groups.names;
    final query = widget.query;
    final visible = [
      for (var i = 0; i < names.length; i++)
        if (query.isEmpty || i == _selected || names[i].toLowerCase().contains(query)) i,
    ];
    final groupMatches = query.isNotEmpty && names[_selected].toLowerCase().contains(query);

    return PopScope(
      canPop: !_inChannels,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToGroups();
      },
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 300,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: visible.length,
          itemBuilder: (context, k) {
            final index = visible[k];
            final selected = index == _selected;
            return ListTile(
              // À l'arrivée, la télécommande part de la catégorie ouverte.
              autofocus: selected,
              focusNode: _node(index),
              selected: selected,
              selectedColor: scheme.onSurface,
              selectedTileColor: scheme.surfaceContainerHigh,
              title: Text(names[index], maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: selected ? Icon(Icons.chevron_right, color: scheme.primary) : null,
              // La catégorie suit la sélection après un court instant : traverser la liste ne charge pas tout.
              onFocusChange: (focused) {
                if (!focused) return;
                _follow?.cancel();
                _follow = Timer(const Duration(milliseconds: 350), () {
                  if (mounted) _select(index);
                });
              },
              onTap: () => _select(index),
            );
          },
        ),
      ),
      VerticalDivider(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
      Expanded(
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onChannelsKey,
          onFocusChange: (inside) => setState(() => _inChannels = inside),
          child: FutureBuilder<List<Channel>>(
            key: ValueKey(_selected),
            future: widget.groups.channels(_selected),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ListView(children: [FailureRow(message: '${snapshot.error}', onRetry: () => setState(() {}))]);
              }
              final channels = snapshot.data;
              if (channels == null) return ListView(children: const [LoadingRow(text: 'Chargement…')]);
              final shown = query.isEmpty || groupMatches
                  ? channels
                  : channels.where((c) => c.name.toLowerCase().contains(query)).toList();
              if (shown.isEmpty) {
                return ListView(children: [
                  ListTile(title: Text(channels.isEmpty ? 'Catégorie vide.' : 'Aucune chaîne ne correspond dans cette catégorie.')),
                ]);
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _ListHeader(title: names[_selected], position: _position, count: shown.length),
                Expanded(
                  child: Scrollbar(
                    controller: _channelsScroll,
                    thumbVisibility: true,
                    thickness: 6,
                    radius: const Radius.circular(3),
                    child: ListView.builder(
                      controller: _channelsScroll,
                      padding: const EdgeInsets.only(bottom: 8, right: 12),
                      itemCount: shown.length,
                      itemBuilder: (_, index) => Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onFocusChange: (focused) {
                          if (focused && _position != index) setState(() => _position = index);
                        },
                        child: widget.tile(shown[index], _selected),
                      ),
                    ),
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    ]),
    );
  }
}

/// Nom de la liste et position de la sélection : « FR| GENERAL · 12 / 240 ».
class ListHeaderCount extends StatelessWidget {
  const ListHeaderCount({super.key, required this.position, required this.count});
  final int? position;
  final int count;

  @override
  Widget build(BuildContext context) => Text(
        position == null ? '$count chaîne${count > 1 ? 's' : ''}' : '${position! + 1} / $count',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
}

class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.title, required this.position, required this.count});
  final String title;
  final int? position;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 24, 6),
        child: Row(children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          ListHeaderCount(position: position, count: count),
        ]),
      );
}
