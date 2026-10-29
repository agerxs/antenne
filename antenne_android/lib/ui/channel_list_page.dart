import 'package:flutter/material.dart';

import '../core/models.dart';
import 'widgets.dart';

/// Liste filtrable de chaînes (playlist M3U ou favoris) : recherche et filtre par groupe.
class ChannelListPage extends StatefulWidget {
  const ChannelListPage({
    super.key,
    required this.title,
    required this.channels,
    required this.emptyTitle,
    required this.emptyMessage,
    this.loading = false,
  });

  final String title;
  final List<Channel> channels;
  final String emptyTitle;
  final String emptyMessage;
  final bool loading;

  @override
  State<ChannelListPage> createState() => _ChannelListPageState();
}

class _ChannelListPageState extends State<ChannelListPage> {
  final _search = TextEditingController();
  String? _group;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _groups => {for (final c in widget.channels) if (c.group != null) c.group!}.toList();

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = widget.channels
        .where((c) => (_group == null || c.group == _group) && (query.isEmpty || c.name.toLowerCase().contains(query)))
        .toList();
    final groups = _groups;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (groups.length > 1)
            PopupMenuButton<String?>(
              tooltip: 'Groupes',
              icon: Icon(_group == null ? Icons.filter_list : Icons.filter_list_alt),
              initialValue: _group,
              onSelected: (value) => setState(() => _group = value),
              itemBuilder: (_) => [
                const PopupMenuItem(value: null, child: Text('Tous les groupes')),
                for (final group in groups) PopupMenuItem(value: group, child: Text(group)),
              ],
            ),
        ],
        bottom: widget.channels.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(64),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SearchBar(
                    controller: _search,
                    hintText: 'Rechercher une chaîne',
                    leading: const Icon(Icons.search),
                    elevation: const WidgetStatePropertyAll(0),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
      ),
      body: widget.loading
          ? const Center(child: CircularProgressIndicator())
          : widget.channels.isEmpty
              ? EmptyState(icon: Icons.tv, title: widget.emptyTitle, message: widget.emptyMessage)
              : visible.isEmpty
                  ? EmptyState(icon: Icons.search_off, title: 'Aucun résultat', message: 'Rien ne correspond à « ${_search.text} ».')
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) => ChannelTile(channel: visible[index]),
                    ),
    );
  }
}
