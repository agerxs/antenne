import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'm3u_parser.dart';
import 'models.dart';
import 'xtream.dart';

class LibraryException implements Exception {
  const LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Mots de passe des comptes, rangés à part des playlists.
abstract class PasswordStore {
  Future<String?> read(String playlistId);
  Future<void> write(String playlistId, String password);
  Future<void> delete(String playlistId);
}

/// Stockage chiffré par le keystore d'Android.
class SecurePasswordStore implements PasswordStore {
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String playlistId) => _storage.read(key: 'account.$playlistId');
  @override
  Future<void> write(String playlistId, String password) => _storage.write(key: 'account.$playlistId', value: password);
  @override
  Future<void> delete(String playlistId) => _storage.delete(key: 'account.$playlistId');
}

/// Playlists, favoris et positions de lecture, enregistrés en JSON dans le dossier de l'app.
class Library extends ChangeNotifier {
  Library._(this._directory, this._cacheDirectory, this._client, this._passwords);

  static Future<Library> load({
    required Directory directory,
    required Directory cacheDirectory,
    http.Client? client,
    PasswordStore? passwords,
  }) async {
    final library = Library._(directory, cacheDirectory, client ?? http.Client(), passwords ?? SecurePasswordStore());
    await library._read();
    return library;
  }

  final Directory _directory;
  final Directory _cacheDirectory;
  final http.Client _client;
  final PasswordStore _passwords;

  final List<Playlist> _playlists = [];
  final List<Channel> _favorites = [];

  /// Dans l'ordre de dernière mise à jour : les plus anciennes partent en premier.
  final Map<String, PlaybackProgress> _progress = {};
  final Map<String, List<Channel>> _channelCache = {};
  final Map<String, String> _passwordCache = {};
  final Set<String> refreshing = {};

  static const progressLimit = 300;

  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<Channel> get favorites => List.unmodifiable(_favorites);

  Playlist? playlist(String id) => _playlists.where((p) => p.id == id).firstOrNull;

  Future<List<Channel>> channels(String playlistId) async {
    if (_channelCache[playlistId] case final cached?) return cached;
    final file = _channelsFile(playlistId);
    if (!await file.exists()) return const [];
    final list = (jsonDecode(await file.readAsString()) as List).cast<Map<String, dynamic>>();
    return _channelCache[playlistId] = list.map(Channel.fromJson).toList();
  }

  // Playlists

  Future<Playlist> addRemote(String name, String url) async {
    final channels = await _download(url);
    return _insert(
      Playlist(id: _newId(), name: name, kind: PlaylistKind.remote, url: url, channelCount: channels.length, updatedAt: DateTime.now()),
      channels,
    );
  }

  Future<Playlist> addFile(String name, String fileName, String content) async {
    final channels = _parse(content);
    return _insert(
      Playlist(id: _newId(), name: name, kind: PlaylistKind.file, fileName: fileName, channelCount: channels.length, updatedAt: DateTime.now()),
      channels,
    );
  }

  Future<Playlist> addXtream(String name, Uri server, String username, String password) async {
    final client = XtreamClient(server: server, username: username, password: password, client: _client, cacheDirectory: _cacheDirectory);
    final account = await client.accountInfo(forceRefresh: true);
    if (!account.isActive) throw LibraryException("Ce compte n'est pas actif (statut : ${account.status}).");

    final playlist = Playlist(
      id: _newId(),
      name: name,
      kind: PlaylistKind.xtream,
      server: server.toString(),
      username: username,
      updatedAt: DateTime.now(),
    );
    await _passwords.write(playlist.id, password);
    _passwordCache[playlist.id] = password;
    _playlists.add(playlist);
    await _save();
    return playlist;
  }

  /// Client du compte, ou null si ce n'est pas un compte ou que son mot de passe manque.
  Future<XtreamClient?> xtreamClient(String playlistId) async {
    final playlist = this.playlist(playlistId);
    if (playlist == null || playlist.kind != PlaylistKind.xtream) return null;
    final password = _passwordCache[playlistId] ??= await _passwords.read(playlistId) ?? '';
    if (password.isEmpty) return null;
    return XtreamClient(
      server: Uri.parse(playlist.server!),
      username: playlist.username!,
      password: password,
      client: _client,
      cacheDirectory: _cacheDirectory,
    );
  }

  /// Client du compte d'où vient une chaîne (utile pour un favori, qui ne connaît pas sa playlist).
  Future<XtreamClient?> xtreamClientForChannel(Channel channel) async {
    final uri = Uri.tryParse(channel.url);
    if (uri == null) return null;
    for (final playlist in _playlists.where((p) => p.kind == PlaylistKind.xtream)) {
      final server = Uri.parse(playlist.server!);
      if (uri.host == server.host && uri.port == server.port && uri.pathSegments.contains(playlist.username)) {
        return xtreamClient(playlist.id);
      }
    }
    return null;
  }

  Future<void> refresh(String playlistId) async {
    final playlist = this.playlist(playlistId);
    if (playlist == null || refreshing.contains(playlistId)) return;
    switch (playlist.kind) {
      case PlaylistKind.file:
        return;
      case PlaylistKind.xtream:
        // Les listes se rechargent à la demande : vider le cache suffit.
        await (await xtreamClient(playlistId))?.clearCache();
        _replace(playlist.copyWith(updatedAt: DateTime.now()));
        await _save();
      case PlaylistKind.remote:
        refreshing.add(playlistId);
        notifyListeners();
        try {
          final channels = await _download(playlist.url!);
          await _writeChannels(playlistId, channels);
          _replace(playlist.copyWith(channelCount: channels.length, updatedAt: DateTime.now()));
          await _save();
        } finally {
          refreshing.remove(playlistId);
          notifyListeners();
        }
    }
  }

  Future<void> rename(String playlistId, String name) async {
    final playlist = this.playlist(playlistId);
    if (playlist == null || name.trim().isEmpty) return;
    _replace(playlist.copyWith(name: name.trim()));
    await _save();
  }

  Future<void> delete(String playlistId) async {
    await (await xtreamClient(playlistId))?.clearCache();
    await _passwords.delete(playlistId);
    _passwordCache.remove(playlistId);
    _playlists.removeWhere((p) => p.id == playlistId);
    _channelCache.remove(playlistId);
    final file = _channelsFile(playlistId);
    if (await file.exists()) await file.delete();
    await _save();
  }

  // Favoris

  bool isFavorite(Channel channel) => _favorites.contains(channel);

  Future<void> toggleFavorite(Channel channel) async {
    if (!_favorites.remove(channel)) _favorites.add(channel);
    await _save();
  }

  // Reprise de lecture

  PlaybackProgress? progress(Channel channel) => _progress[channel.key];

  /// Note où en est un film ou un épisode. Le direct (sans durée) et les extraits sont ignorés.
  Future<void> recordProgress(Channel channel, double position, double duration) async {
    if (!PlaybackProgress.isTrackable(duration) || !position.isFinite || position < 0) return;
    final key = channel.key;
    // Quelques secondes regardées par erreur ne doivent pas créer d'entrée.
    if (!_progress.containsKey(key) && position < 10) return;
    _progress.remove(key);
    _progress[key] = PlaybackProgress(position: position, duration: duration);
    while (_progress.length > progressLimit) {
      _progress.remove(_progress.keys.first);
    }
    await _save();
  }

  // Privé

  Future<Playlist> _insert(Playlist playlist, List<Channel> channels) async {
    await _writeChannels(playlist.id, channels);
    _playlists.add(playlist);
    await _save();
    return playlist;
  }

  void _replace(Playlist playlist) {
    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index >= 0) _playlists[index] = playlist;
  }

  Future<List<Channel>> _download(String url) async {
    final response = await _client.get(Uri.parse(url), headers: {'User-Agent': userAgent});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LibraryException('Le serveur a refusé la playlist (code ${response.statusCode}). Vérifie le lien ou ton abonnement.');
    }
    return _parse(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  List<Channel> _parse(String content) {
    final channels = M3uParser.parse(content);
    if (channels.isEmpty) throw const LibraryException('Aucune chaîne trouvée dans cette playlist.');
    return channels;
  }

  Future<void> _writeChannels(String playlistId, List<Channel> channels) async {
    final file = _channelsFile(playlistId);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(channels.map((c) => c.toJson()).toList()), flush: true);
    _channelCache[playlistId] = channels;
  }

  Future<void> _read() async {
    final file = _libraryFile;
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _playlists.addAll((json['playlists'] as List? ?? []).cast<Map<String, dynamic>>().map(Playlist.fromJson));
    _favorites.addAll((json['favorites'] as List? ?? []).cast<Map<String, dynamic>>().map(Channel.fromJson));
    (json['progress'] as Map? ?? {}).forEach((key, value) {
      _progress[key as String] = PlaybackProgress.fromJson((value as Map).cast<String, dynamic>());
    });
  }

  Future<void> _save() async {
    await _directory.create(recursive: true);
    final json = {
      'playlists': _playlists.map((p) => p.toJson()).toList(),
      'favorites': _favorites.map((c) => c.toJson()).toList(),
      'progress': _progress.map((key, value) => MapEntry(key, value.toJson())),
    };
    final temporary = File('${_libraryFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(_libraryFile.path);
    notifyListeners();
  }

  File get _libraryFile => File('${_directory.path}/library.json');
  File _channelsFile(String playlistId) => File('${_directory.path}/channels/$playlistId.json');

  static String _newId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
