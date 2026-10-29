import 'package:flutter/material.dart';

import '../core/models.dart';
import 'add_playlist_page.dart';
import 'channel_list_page.dart';
import 'library_scope.dart';
import 'widgets.dart';
import 'xtream_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final playlists = library.playlists;
    return Scaffold(
      appBar: AppBar(title: const Text('Antenne')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          ListTile(
            leading: const Icon(Icons.star_border),
            title: const Text('Favoris'),
            trailing: Text('${library.favorites.length}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _FavoritesPage())),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Playlists', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          if (playlists.isEmpty)
            const SizedBox(
              height: 320,
              child: EmptyState(
                icon: Icons.playlist_add,
                title: 'Aucune playlist',
                message: 'Ajoute ton compte IPTV, un lien M3U ou un fichier .m3u.',
              ),
            ),
          for (final playlist in playlists) _PlaylistTile(playlist: playlist, refreshing: library.refreshing.contains(playlist.id)),
        ],
      ),
    );
  }

  static Future<void> _add(BuildContext context) async {
    final playlist = await Navigator.of(context).push<Playlist>(MaterialPageRoute(builder: (_) => const AddPlaylistPage()));
    if (playlist != null && context.mounted) openPlaylist(context, playlist);
  }
}

void openPlaylist(BuildContext context, Playlist playlist) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => playlist.kind == PlaylistKind.xtream ? XtreamPage(playlist: playlist) : PlaylistChannelsPage(playlist: playlist),
  ));
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.playlist, required this.refreshing});
  final Playlist playlist;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final subtitle = switch (playlist.kind) {
      PlaylistKind.xtream => 'Compte ${playlist.username} · Direct, films, séries',
      _ => '${playlist.channelCount} ${playlist.channelCount > 1 ? 'chaînes' : 'chaîne'}',
    };
    return ListTile(
      leading: Icon(playlist.kind == PlaylistKind.xtream ? Icons.live_tv_outlined : Icons.list_alt_outlined),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: refreshing
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(icon: const Icon(Icons.more_vert), tooltip: 'Actions', onPressed: () => _actions(context)),
      onTap: () => openPlaylist(context, playlist),
      onLongPress: () => _actions(context),
    );
  }

  Future<void> _actions(BuildContext context) async {
    final library = LibraryScope.read(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (playlist.kind != PlaylistKind.file)
            ListTile(leading: const Icon(Icons.refresh), title: const Text('Actualiser'), onTap: () => Navigator.pop(sheet, 'refresh')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Renommer'), onTap: () => Navigator.pop(sheet, 'rename')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
            title: Text('Supprimer', style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
            onTap: () => Navigator.pop(sheet, 'delete'),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'refresh':
        try {
          await library.refresh(playlist.id);
        } catch (error) {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Actualisation impossible : $error')));
        }
      case 'rename':
        final name = await _askName(context);
        if (name != null) await library.rename(playlist.id, name);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text('Supprimer « ${playlist.name} » ?'),
            content: const Text("Ses chaînes disparaîtront de l'app. Tes favoris restent."),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Annuler')),
              FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Supprimer')),
            ],
          ),
        );
        if (confirmed == true) await library.delete(playlist.id);
    }
  }

  Future<String?> _askName(BuildContext context) {
    final controller = TextEditingController(text: playlist.name);
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Renommer la playlist'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text), child: const Text('Renommer')),
        ],
      ),
    );
  }
}

class _FavoritesPage extends StatelessWidget {
  const _FavoritesPage();

  @override
  Widget build(BuildContext context) {
    final favorites = LibraryScope.of(context).favorites;
    return ChannelListPage(
      title: 'Favoris',
      channels: favorites,
      emptyTitle: 'Aucun favori',
      emptyMessage: 'Appuie longuement sur une chaîne, un film ou un épisode pour l’ajouter ici.',
    );
  }
}

/// Chaînes d'une playlist M3U, chargées depuis le disque.
class PlaylistChannelsPage extends StatelessWidget {
  const PlaylistChannelsPage({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final current = library.playlist(playlist.id) ?? playlist;
    return FutureBuilder<List<Channel>>(
      // L'heure d'actualisation change la clé : la liste se recharge après « Actualiser ».
      key: ValueKey(current.updatedAt),
      future: library.channels(playlist.id),
      builder: (context, snapshot) => ChannelListPage(
        title: current.name,
        channels: snapshot.data ?? const [],
        loading: snapshot.connectionState != ConnectionState.done,
        emptyTitle: 'Playlist vide',
        emptyMessage: 'Actualise-la depuis l’écran d’accueil.',
      ),
    );
  }
}
