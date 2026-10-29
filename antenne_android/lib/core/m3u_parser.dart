import 'models.dart';

/// Lit les playlists M3U / M3U8 « étendues » utilisées par les fournisseurs IPTV.
class M3uParser {
  static final _attribute = RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"');

  static List<Channel> parse(String content) {
    final channels = <Channel>[];
    var pending = _Pending();

    for (var line in content.split(RegExp(r'\r\n|\r|\n'))) {
      line = line.trim();
      if (line.startsWith('﻿')) line = line.substring(1);
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        final extinf = _after('#EXTINF:', line);
        final group = _after('#EXTGRP:', line);
        final option = _after('#EXTVLCOPT:', line);
        if (extinf != null) {
          _applyExtinf(pending, extinf);
        } else if (group != null && pending.group == null) {
          pending.group = _blankToNull(group);
        } else if (option != null) {
          final agent = _after('http-user-agent=', option);
          if (agent != null) pending.userAgent = _blankToNull(agent);
        }
        continue;
      }

      final uri = Uri.tryParse(line);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        channels.add(pending.toChannel(line, uri));
      }
      pending = _Pending();
    }
    return channels;
  }

  static String? _after(String prefix, String line) {
    if (line.length < prefix.length || line.substring(0, prefix.length).toUpperCase() != prefix.toUpperCase()) {
      return null;
    }
    return line.substring(prefix.length).trim();
  }

  static void _applyExtinf(_Pending pending, String body) {
    // Le titre suit la première virgule hors guillemets : les attributs peuvent en contenir.
    var inQuotes = false;
    var comma = -1;
    for (var i = 0; i < body.length; i++) {
      final char = body[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        comma = i;
        break;
      }
    }
    final head = comma >= 0 ? body.substring(0, comma) : body;
    if (comma >= 0) pending.title = _blankToNull(body.substring(comma + 1));
    for (final match in _attribute.allMatches(head)) {
      pending.attributes[match.group(1)!.toLowerCase()] = match.group(2)!;
    }
  }
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

class _Pending {
  String? title;
  final attributes = <String, String>{};
  String? group;
  String? userAgent;

  Channel toChannel(String url, Uri uri) {
    final lastSegment = uri.pathSegments.isEmpty ? null : uri.pathSegments.last.split('.').first;
    final name = title ?? _blankToNull(attributes['tvg-name']) ?? _blankToNull(lastSegment) ?? 'Chaîne sans nom';
    return Channel(
      name: name,
      url: url,
      logoUrl: _blankToNull(attributes['tvg-logo']),
      group: _blankToNull(attributes['group-title']) ?? group,
      tvgId: _blankToNull(attributes['tvg-id']),
      userAgent: userAgent,
    );
  }
}
