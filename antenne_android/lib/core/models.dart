import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Une chaîne, un film ou un épisode : tout ce qui se lit.
class Channel {
  const Channel({
    required this.name,
    required this.url,
    this.logoUrl,
    this.group,
    this.tvgId,
    this.userAgent,
    this.streamId,
  });

  final String name;
  final String url;
  final String? logoUrl;
  final String? group;
  final String? tvgId;

  /// Valeur de `#EXTVLCOPT:http-user-agent`, exigée par certains fournisseurs.
  final String? userAgent;

  /// Identifiant de la chaîne en direct chez un serveur Xtream, pour son guide des programmes.
  final String? streamId;

  /// Clé stable d'une chaîne, sans exposer son lien (qui peut contenir un mot de passe).
  String get key => sha256.convert(utf8.encode(url)).toString().substring(0, 32);

  bool get isLive => streamId != null;

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (logoUrl != null) 'logoUrl': logoUrl,
        if (group != null) 'group': group,
        if (tvgId != null) 'tvgId': tvgId,
        if (userAgent != null) 'userAgent': userAgent,
        if (streamId != null) 'streamId': streamId,
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        name: json['name'] as String,
        url: json['url'] as String,
        logoUrl: json['logoUrl'] as String?,
        group: json['group'] as String?,
        tvgId: json['tvgId'] as String?,
        userAgent: json['userAgent'] as String?,
        streamId: json['streamId'] as String?,
      );

  @override
  bool operator ==(Object other) => other is Channel && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

enum PlaylistKind { remote, file, xtream }

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.kind,
    this.url,
    this.fileName,
    this.server,
    this.username,
    this.channelCount = 0,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final PlaylistKind kind;

  /// Lien M3U (`remote`).
  final String? url;

  /// Nom du fichier importé (`file`).
  final String? fileName;

  /// Serveur et identifiant d'un compte (`xtream`) ; le mot de passe vit dans le stockage sécurisé.
  final String? server;
  final String? username;

  final int channelCount;
  final DateTime updatedAt;

  Playlist copyWith({String? name, int? channelCount, DateTime? updatedAt}) => Playlist(
        id: id,
        name: name ?? this.name,
        kind: kind,
        url: url,
        fileName: fileName,
        server: server,
        username: username,
        channelCount: channelCount ?? this.channelCount,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        if (url != null) 'url': url,
        if (fileName != null) 'fileName': fileName,
        if (server != null) 'server': server,
        if (username != null) 'username': username,
        'channelCount': channelCount,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: PlaylistKind.values.byName(json['kind'] as String),
        url: json['url'] as String?,
        fileName: json['fileName'] as String?,
        server: json['server'] as String?,
        username: json['username'] as String?,
        channelCount: json['channelCount'] as int? ?? 0,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

/// Où en est la lecture d'un film ou d'un épisode, en secondes.
class PlaybackProgress {
  const PlaybackProgress({required this.position, required this.duration});

  final double position;
  final double duration;

  /// Au-delà, le générique est entamé : le titre est considéré comme vu.
  static const finishedFraction = 0.95;

  /// En deçà, reprendre n'apporte rien : on repart du début.
  static const minimumResumePosition = 30.0;

  /// Le direct n'a pas de durée ; un extrait de moins d'une minute ne mérite pas d'être suivi.
  static const minimumTrackedDuration = 60.0;

  double get fraction => duration > 0 ? (position / duration).clamp(0, 1).toDouble() : 0;
  bool get isFinished => fraction >= finishedFraction;

  /// Position à laquelle reprendre, ou null pour lire depuis le début.
  double? get resumePosition => position >= minimumResumePosition && !isFinished ? position : null;

  static bool isTrackable(double duration) => duration.isFinite && duration >= minimumTrackedDuration;

  Map<String, dynamic> toJson() => {'position': position, 'duration': duration};

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) => PlaybackProgress(
        position: (json['position'] as num).toDouble(),
        duration: (json['duration'] as num).toDouble(),
      );
}

/// Une émission du guide des programmes.
class EpgProgramme {
  const EpgProgramme({required this.title, this.summary, required this.start, required this.end});

  final String title;
  final String? summary;
  final DateTime start;
  final DateTime end;

  bool isOnAir([DateTime? at]) {
    final now = at ?? DateTime.now();
    return !start.isAfter(now) && now.isBefore(end);
  }

  /// Part écoulée de l'émission, de 0 à 1.
  double progress([DateTime? at]) {
    final length = end.difference(start).inSeconds;
    if (length <= 0) return 0;
    final elapsed = (at ?? DateTime.now()).difference(start).inSeconds;
    return (elapsed / length).clamp(0, 1).toDouble();
  }
}

enum ContentKind { live, movies, series }

class XtreamCategory {
  const XtreamCategory({required this.id, required this.name});
  final String id;
  final String name;
}

class XtreamSeries {
  const XtreamSeries({
    required this.id,
    required this.name,
    this.coverUrl,
    this.plot,
    this.genre,
    this.releaseDate,
    this.rating,
  });

  final String id;
  final String name;
  final String? coverUrl;
  final String? plot;
  final String? genre;
  final String? releaseDate;
  final String? rating;
}

class XtreamEpisode {
  const XtreamEpisode({this.number, required this.title, this.duration, required this.channel});
  final int? number;
  final String title;
  final String? duration;
  final Channel channel;
}

class XtreamSeason {
  const XtreamSeason({required this.number, required this.episodes});
  final int number;
  final List<XtreamEpisode> episodes;
}

class XtreamSeriesDetail {
  const XtreamSeriesDetail({this.plot, this.genre, this.releaseDate, this.coverUrl, required this.seasons});
  final String? plot;
  final String? genre;
  final String? releaseDate;
  final String? coverUrl;
  final List<XtreamSeason> seasons;
}

class XtreamAccountInfo {
  const XtreamAccountInfo({
    required this.status,
    required this.isTrial,
    this.expiresAt,
    this.maxConnections,
  });

  final String status;
  final bool isTrial;
  final DateTime? expiresAt;
  final int? maxConnections;

  bool get isActive => status.toLowerCase() == 'active';
}
