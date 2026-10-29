import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Identité envoyée aux serveurs : certains panneaux coupent la connexion aux agents
/// qu'ils prennent pour des robots (`curl`, `Dart/…`).
const userAgent = 'Antenne/1.0 (Android)';

class XtreamException implements Exception {
  const XtreamException(this.message);
  final String message;

  static const invalidCredentials = XtreamException('Utilisateur ou mot de passe refusé par le serveur.');
  static const badResponse =
      XtreamException("Le serveur a répondu quelque chose d'illisible. Vérifie l'adresse du serveur.");
  static XtreamException http(int code) => XtreamException('Le serveur a refusé la demande (code $code).');

  @override
  String toString() => message;
}

/// Accepte « serveur.com:8080 » comme « http://serveur.com:8080/ ».
Uri? xtreamServer(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  final path = uri.path.replaceAll(RegExp(r'^/+|/+$'), '');
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path.isEmpty ? '' : '/$path');
}

/// Interroge `player_api.php` catégorie par catégorie, au lieu de la playlist complète
/// (plusieurs centaines de milliers d'entrées chez certains fournisseurs).
class XtreamClient {
  XtreamClient({
    required this.server,
    required this.username,
    required String password,
    http.Client? client,
    Directory? cacheDirectory,
  })  : _password = password,
        _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory == null
            ? null
            : Directory('${cacheDirectory.path}/xtream/${_digest('$server|$username')}');

  final Uri server;
  final String username;
  final String _password;
  final http.Client _client;
  final Directory? _cacheDirectory;

  Future<XtreamAccountInfo> accountInfo({bool forceRefresh = false}) {
    return _load(null, const {}, const Duration(minutes: 5), forceRefresh, (json) {
      final info = (json is Map ? json['user_info'] : null);
      if (info is! Map) throw XtreamException.badResponse;
      if (_int(info['auth']) == 0) throw XtreamException.invalidCredentials;
      final expiry = _double(info['exp_date']);
      return XtreamAccountInfo(
        status: _text(info['status']) ?? '?',
        isTrial: _int(info['is_trial']) == 1,
        expiresAt: expiry == null ? null : DateTime.fromMillisecondsSinceEpoch((expiry * 1000).round()),
        maxConnections: _int(info['max_connections']),
      );
    });
  }

  Future<List<XtreamCategory>> categories(ContentKind kind, {bool forceRefresh = false}) {
    final action = switch (kind) {
      ContentKind.live => 'get_live_categories',
      ContentKind.movies => 'get_vod_categories',
      ContentKind.series => 'get_series_categories',
    };
    return _load(action, const {}, const Duration(hours: 12), forceRefresh, (json) {
      return [
        for (final record in _records(json))
          if (_text(record['category_id']) case final id?)
            XtreamCategory(id: id, name: _text(record['category_name']) ?? 'Sans nom'),
      ];
    });
  }

  /// Chaînes en direct ou films d'une catégorie, prêts à lire.
  Future<List<Channel>> channels(ContentKind kind, XtreamCategory category, {bool forceRefresh = false}) {
    assert(kind != ContentKind.series, 'Les séries se chargent avec series()');
    final action = kind == ContentKind.live ? 'get_live_streams' : 'get_vod_streams';
    return _load(action, {'category_id': category.id}, const Duration(hours: 6), forceRefresh, (json) {
      return [
        for (final record in _records(json))
          if (_text(record['stream_id']) case final id?)
            Channel(
              name: _text(record['name']) ?? 'Sans nom',
              url: kind == ContentKind.live
                  ? _streamUrl('live', id, 'm3u8')
                  : _streamUrl('movie', id, _text(record['container_extension']) ?? 'mp4'),
              logoUrl: _text(record['stream_icon']),
              group: category.name,
              tvgId: _text(record['epg_channel_id']),
              streamId: kind == ContentKind.live ? id : null,
            ),
      ];
    });
  }

  Future<List<XtreamSeries>> series(XtreamCategory category, {bool forceRefresh = false}) {
    return _load('get_series', {'category_id': category.id}, const Duration(hours: 6), forceRefresh, (json) {
      return [
        for (final record in _records(json))
          if (_text(record['series_id']) case final id?)
            XtreamSeries(
              id: id,
              name: _text(record['name']) ?? 'Sans nom',
              coverUrl: _text(record['cover']),
              plot: _text(record['plot']),
              genre: _text(record['genre']),
              releaseDate: _text(record['releaseDate']) ?? _text(record['release_date']),
              rating: _text(record['rating']),
            ),
      ];
    });
  }

  Future<XtreamSeriesDetail> seriesDetail(XtreamSeries series, {bool forceRefresh = false}) {
    return _load('get_series_info', {'series_id': series.id}, const Duration(hours: 6), forceRefresh, (json) {
      if (json is! Map) throw XtreamException.badResponse;
      final info = json['info'] is Map ? json['info'] as Map : const {};

      // « episodes » est un objet { "1": [...] } ou un tableau de saisons selon les serveurs.
      final raw = <(int?, Map)>[];
      final episodes = json['episodes'];
      if (episodes is Map) {
        episodes.forEach((key, value) => raw.addAll(_records(value).map((r) => (int.tryParse('$key'), r))));
      } else if (episodes is List) {
        for (final value in episodes) {
          raw.addAll(_records(value).map((r) => (null, r)));
        }
      }

      final seasons = <int, List<XtreamEpisode>>{};
      for (final (key, record) in raw) {
        final id = _text(record['id']);
        if (id == null) continue;
        final season = _int(record['season']) ?? key ?? 1;
        final number = _int(record['episode_num']);
        final details = record['info'] is Map ? record['info'] as Map : const {};
        final title = _text(record['title']) ?? 'Épisode ${number ?? id}';
        seasons.putIfAbsent(season, () => []).add(XtreamEpisode(
              number: number,
              title: title,
              duration: _text(details['duration']),
              channel: Channel(
                name: title,
                url: _streamUrl('series', id, _text(record['container_extension']) ?? 'mp4'),
                logoUrl: _text(details['movie_image']) ?? series.coverUrl,
                group: series.name,
              ),
            ));
      }

      final numbers = seasons.keys.toList()..sort();
      return XtreamSeriesDetail(
        plot: _text(info['plot']) ?? series.plot,
        genre: _text(info['genre']) ?? series.genre,
        releaseDate: _text(info['releaseDate']) ?? series.releaseDate,
        coverUrl: _text(info['cover']) ?? series.coverUrl,
        seasons: [
          for (final number in numbers)
            XtreamSeason(
              number: number,
              episodes: seasons[number]!..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0)),
            ),
        ],
      );
    });
  }

  /// Émission en cours et suivantes d'une chaîne en direct, triées, sans celles déjà terminées.
  Future<List<EpgProgramme>> guide(Channel channel, {int limit = 6, bool forceRefresh = false}) async {
    final streamId = channel.streamId;
    if (streamId == null) return [];
    final programmes = await _load(
        'get_short_epg', {'stream_id': streamId, 'limit': '$limit'}, const Duration(minutes: 15), forceRefresh,
        (json) {
      final listings = json is Map ? json['epg_listings'] : null;
      return [
        for (final record in _records(listings))
          if (_double(record['start_timestamp']) case final start?)
            if (_double(record['stop_timestamp'] ?? record['end_timestamp']) case final end? when end > start)
              EpgProgramme(
                title: _decoded(record['title']) ?? 'Programme sans titre',
                summary: _decoded(record['description']),
                start: DateTime.fromMillisecondsSinceEpoch((start * 1000).round()),
                end: DateTime.fromMillisecondsSinceEpoch((end * 1000).round()),
              ),
      ];
    });
    final now = DateTime.now();
    return programmes.where((p) => p.end.isAfter(now)).toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  Future<void> clearCache() async {
    final directory = _cacheDirectory;
    if (directory != null && await directory.exists()) await directory.delete(recursive: true);
  }

  // Réseau et cache

  Future<T> _load<T>(
    String? action,
    Map<String, String> extra,
    Duration maxAge,
    bool force,
    T Function(Object? json) parse,
  ) async {
    final file = _cacheFile(action, extra);
    if (!force && file != null && await file.exists()) {
      final age = DateTime.now().difference(await file.lastModified());
      if (age < maxAge) {
        try {
          return parse(jsonDecode(await file.readAsString()));
        } catch (_) {
          // Cache illisible : on redemande au serveur.
        }
      }
    }

    final response = await _client.get(_endpoint(action, extra), headers: {'User-Agent': userAgent});
    if (response.statusCode < 200 || response.statusCode >= 300) throw XtreamException.http(response.statusCode);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      throw XtreamException.badResponse;
    }
    final value = parse(json);
    if (file != null) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes, flush: true);
    }
    return value;
  }

  Uri _endpoint(String? action, Map<String, String> extra) {
    final query = [
      ('username', username),
      ('password', _password),
      if (action != null) ('action', action),
      ...extra.entries.map((e) => (e.key, e.value)),
    ].map((pair) => '${pair.$1}=${_encode(pair.$2)}').join('&');
    return Uri.parse('${server.toString()}/player_api.php?$query');
  }

  File? _cacheFile(String? action, Map<String, String> extra) {
    final directory = _cacheDirectory;
    if (directory == null) return null;
    final name = [action ?? 'account', ...extra.entries.map((e) => '${e.key}-${e.value}')]
        .join('_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return File('${directory.path}/$name.json');
  }

  String _streamUrl(String kind, String id, String extension) =>
      '$server/$kind/${Uri.encodeComponent(username)}/${Uri.encodeComponent(_password)}/$id.$extension';

  static String _digest(String value) => sha256.convert(utf8.encode(value)).toString().substring(0, 24);

  /// « + » serait lu comme une espace par la plupart des serveurs.
  static String _encode(String value) => Uri.encodeQueryComponent(value).replaceAll('+', '%20');
}

// Lecture tolérante du JSON (nombres en texte, champs nuls, objets vides…)

List<Map> _records(Object? json) {
  if (json is List) return json.whereType<Map>().toList();
  if (json is Map) return json.values.whereType<Map>().toList();
  return const [];
}

String? _text(Object? value) => switch (value) {
      String s when s.trim().isNotEmpty => s.trim(),
      num n => n is int || n == n.roundToDouble() ? n.toInt().toString() : n.toString(),
      _ => null,
    };

int? _int(Object? value) => switch (value) {
      num n => n.toInt(),
      bool b => b ? 1 : 0,
      String s => int.tryParse(s.trim()),
      _ => null,
    };

double? _double(Object? value) => switch (value) {
      num n => n.toDouble(),
      String s => double.tryParse(s.trim()),
      _ => null,
    };

/// Les panneaux Xtream encodent titres et descriptions du guide en base64 (la plupart du temps).
String? _decoded(Object? value) {
  final raw = _text(value);
  if (raw == null) return null;
  if (raw.length % 4 == 0 && RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(raw)) {
    try {
      final decoded = utf8.decode(base64.decode(raw));
      if (!decoded.runes.any((r) => r < 32 && r != 10)) {
        return decoded.trim().isEmpty ? null : decoded.trim();
      }
    } on FormatException {
      // Pas du base64 : texte brut.
    }
  }
  return raw;
}
