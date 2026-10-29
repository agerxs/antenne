import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/xtream.dart';
import 'library_scope.dart';
import 'series_page.dart';
import 'widgets.dart';

/// Un compte Xtream : Direct, Films et Séries, chaque catégorie chargée quand on l'ouvre.
class XtreamPage extends StatefulWidget {
  const XtreamPage({super.key, required this.playlist});
  final Playlist playlist;

  @override
  State<XtreamPage> createState() => _XtreamPageState();
}

class _XtreamPageState extends State<XtreamPage> {
  late final Future<XtreamClient?> _client = LibraryScope.read(context).xtreamClient(widget.playlist.id);
  final _search = TextEditingController();
  XtreamAccountInfo? _account;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<XtreamClient?>(
      future: _client,
      builder: (context, snapshot) {
        final client = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(appBar: AppBar(title: Text(widget.playlist.name)), body: const Center(child: CircularProgressIndicator()));
        }
        if (client == null) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.playlist.name)),
            body: const EmptyState(
              icon: Icons.key_off_outlined,
              title: 'Mot de passe introuvable',
              message: 'Supprime ce compte puis ajoute-le à nouveau.',
            ),
          );
        }
        _loadAccount(client);
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.playlist.name),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(124),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SearchBar(
                      controller: _search,
                      hintText: 'Catégorie ou titre ouvert',
                      leading: const Icon(Icons.search),
                      elevation: const WidgetStatePropertyAll(0),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const TabBar(tabs: [Tab(text: 'Direct'), Tab(text: 'Films'), Tab(text: 'Séries')]),
                ]),
              ),
            ),
            body: Column(children: [
              if (_account case final account?) _AccountSummary(account: account),
              Expanded(
                child: TabBarView(children: [
                  for (final kind in ContentKind.values)
                    _CategoryList(
                      key: ValueKey(kind),
                      kind: kind,
                      client: client,
                      playlistId: widget.playlist.id,
                      query: _search.text.trim().toLowerCase(),
                    ),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  var _accountRequested = false;
  void _loadAccount(XtreamClient client) {
    if (_accountRequested) return;
    _accountRequested = true;
    client.accountInfo().then((info) {
      if (mounted) setState(() => _account = info);
    }, onError: (_) {});
  }
}

class _AccountSummary extends StatelessWidget {
  const _AccountSummary({required this.account});
  final XtreamAccountInfo account;

  @override
  Widget build(BuildContext context) {
    final parts = [
      account.isActive ? (account.isTrial ? 'Essai actif' : 'Actif') : 'Statut : ${account.status}',
      if (account.expiresAt case final date?)
        'expire le ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} à ${clock(date)}',
      if (account.maxConnections case final max?) '$max connexion${max > 1 ? 's' : ''} à la fois',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: account.isActive ? Colors.greenAccent : Colors.redAccent),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(parts.join(' · '),
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

sealed class _Items {}

class _Loading extends _Items {}

class _Failed extends _Items {
  _Failed(this.message);
  final String message;
}

class _Loaded extends _Items {
  _Loaded(this.channels, this.series);
  final List<Channel> channels;
  final List<XtreamSeries> series;

  List<String> get names => [...channels.map((c) => c.name), ...series.map((s) => s.name)];
}

class _CategoryList extends StatefulWidget {
  const _CategoryList({super.key, required this.kind, required this.client, required this.playlistId, required this.query});
  final ContentKind kind;
  final XtreamClient client;
  final String playlistId;
  final String query;

  @override
  State<_CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends State<_CategoryList> with AutomaticKeepAliveClientMixin {
  Future<List<XtreamCategory>>? _categories;
  final _items = <String, _Items>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _categories = widget.client.categories(widget.kind);
  }

  Future<void> _reload() async {
    setState(() {
      _categories = widget.client.categories(widget.kind, forceRefresh: true);
      _items.clear();
    });
    await _categories;
  }

  Future<void> _loadItems(XtreamCategory category, {bool force = false}) async {
    if (!force && _items[category.id] is _Loaded) return;
    setState(() => _items[category.id] = _Loading());
    try {
      final loaded = widget.kind == ContentKind.series
          ? _Loaded(const [], await widget.client.series(category, forceRefresh: force))
          : _Loaded(await widget.client.channels(widget.kind, category, forceRefresh: force), const []);
      if (mounted) setState(() => _items[category.id] = loaded);
    } catch (error) {
      if (mounted) setState(() => _items[category.id] = _Failed(error.toString()));
    }
  }

  /// Une catégorie reste visible si son nom correspond, ou si elle est ouverte et contient un titre qui correspond.
  bool _matches(XtreamCategory category) {
    if (widget.query.isEmpty || category.name.toLowerCase().contains(widget.query)) return true;
    final items = _items[category.id];
    return items is _Loaded && items.names.any((n) => n.toLowerCase().contains(widget.query));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: _reload,
      child: FutureBuilder<List<XtreamCategory>>(
        future: _categories,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ListView(children: [FailureRow(message: snapshot.error.toString(), onRetry: _reload)]);
          }
          if (!snapshot.hasData) return ListView(children: const [LoadingRow(text: 'Chargement des catégories…')]);
          final categories = snapshot.data!.where(_matches).toList();
          if (snapshot.data!.isEmpty) {
            return ListView(children: const [ListTile(title: Text('Aucune catégorie dans cette rubrique.'))]);
          }
          return ListView.builder(
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final category = categories[index];
              return ExpansionTile(
                key: PageStorageKey('${widget.kind.name}-${category.id}'),
                title: Text(category.name),
                shape: const Border(),
                collapsedShape: const Border(),
                onExpansionChanged: (expanded) {
                  if (expanded) _loadItems(category);
                },
                children: _children(category),
              );
            },
          );
        },
      ),
    );
  }

  List<Widget> _children(XtreamCategory category) {
    final items = _items[category.id];
    switch (items) {
      case null || _Loading():
        return const [LoadingRow(text: 'Chargement…')];
      case _Failed(:final message):
        return [FailureRow(message: message, onRetry: () => _loadItems(category, force: true))];
      case _Loaded(:final channels, :final series):
        bool visible(String name) => widget.query.isEmpty || name.toLowerCase().contains(widget.query);
        if (channels.isEmpty && series.isEmpty) return const [ListTile(title: Text('Catégorie vide.'))];
        return [
          for (final channel in channels.where((c) => visible(c.name)))
            channel.isLive ? _LiveTile(channel: channel, client: widget.client) : ChannelTile(channel: channel),
          for (final show in series.where((s) => visible(s.name)))
            ListTile(
              leading: ChannelLogo(url: show.coverUrl, name: show.name, width: 36, height: 52),
              title: Text(show.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: _seriesDetails(show) == null ? null : Text(_seriesDetails(show)!),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SeriesPage(series: show, client: widget.client),
              )),
            ),
        ];
    }
  }

  String? _seriesDetails(XtreamSeries show) {
    final parts = [
      if (show.releaseDate case final date? when date.length >= 4) date.substring(0, 4),
      if (show.genre != null) show.genre!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// Ligne d'une chaîne en direct : l'émission en cours remplace le nom de la catégorie.
class _LiveTile extends StatefulWidget {
  const _LiveTile({required this.channel, required this.client});
  final Channel channel;
  final XtreamClient client;

  @override
  State<_LiveTile> createState() => _LiveTileState();
}

class _LiveTileState extends State<_LiveTile> {
  EpgProgramme? _onAir;

  @override
  void initState() {
    super.initState();
    // Seules les lignes affichées demandent leur guide, et la réponse reste en cache.
    widget.client.guide(widget.channel, limit: 2).then((guide) {
      final current = guide.where((p) => p.isOnAir()).firstOrNull;
      if (mounted && current != null) setState(() => _onAir = current);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => ChannelTile(channel: widget.channel, subtitle: _onAir?.title);
}
