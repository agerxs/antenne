import 'dart:convert';
import 'dart:io';

import 'package:antenne/core/library.dart';
import 'package:antenne/core/m3u_parser.dart';
import 'package:antenne/core/models.dart';
import 'package:antenne/core/xtream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serveur en mémoire : réponses par chemin + requête, et compte des appels.
class FakeServer {
  final responses = <String, (int, String)>{};
  final calls = <String, int>{};

  late final client = MockClient((request) async {
    final key = '${request.url.host}${request.url.path}?${request.url.query}';
    calls[key] = (calls[key] ?? 0) + 1;
    expect(request.headers['User-Agent'], userAgent);
    final (status, body) = responses[key] ?? (404, 'introuvable');
    return http.Response.bytes(utf8.encode(body), status);
  });

  void on(String hostPathQuery, String body, {int status = 200}) => responses[hostPathQuery] = (status, body);
}

class MemoryPasswords implements PasswordStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String password) async => values[id] = password;
  @override
  Future<void> delete(String id) async => values.remove(id);
}

void main() {
  group('M3U', () {
    test('lit les attributs étendus', () {
      final channels = M3uParser.parse('#EXTM3U x-tvg-url="http://epg"\n'
          '#EXTINF:-1 tvg-id="rti1.ci" tvg-name="RTI 1" tvg-logo="http://logo/rti1.png" group-title="Côte d\'Ivoire",RTI 1 HD\n'
          'http://stream.example/live/rti1.m3u8');
      expect(channels.single.name, 'RTI 1 HD');
      expect(channels.single.logoUrl, 'http://logo/rti1.png');
      expect(channels.single.group, "Côte d'Ivoire");
      expect(channels.single.tvgId, 'rti1.ci');
    });

    test('une virgule entre guillemets ne coupe pas le titre', () {
      final channel = M3uParser.parse('#EXTINF:-1 group-title="Sport, Foot",Canal+ Sport, Afrique\nhttp://a.example/1.ts').single;
      expect(channel.group, 'Sport, Foot');
      expect(channel.name, 'Canal+ Sport, Afrique');
    });

    test('CRLF, BOM, lignes vides, groupe et agent', () {
      final channels = M3uParser.parse('﻿#EXTM3U\r\n\r\n#EXTINF:-1,Une\r\n#EXTGRP:Infos\r\n'
          '#EXTVLCOPT:http-user-agent=Mozilla/5.0\r\nhttp://a.example/1\r\n#EXTINF:-1,Deux\r\nhttp://a.example/2\r\n');
      expect(channels.map((c) => c.name), ['Une', 'Deux']);
      expect(channels.first.group, 'Infos');
      expect(channels.first.userAgent, 'Mozilla/5.0');
      expect(channels.last.group, isNull);
    });

    test('titre de secours et lignes invalides ignorées', () {
      final channels = M3uParser.parse('#EXTINF:-1 tvg-name="Nommée",\nhttp://a.example/1.m3u8\n'
          '#EXTINF:-1,Cassée\npas une url\nhttp://a.example/live/nue.m3u8');
      expect(channels.map((c) => c.name), ['Nommée', 'nue']);
    });
  });

  group('Xtream', () {
    late FakeServer server;
    late Directory cache;
    setUp(() async {
      server = FakeServer();
      cache = await Directory.systemTemp.createTemp('antenne-cache');
    });

    XtreamClient client(String host) => XtreamClient(
          server: Uri.parse('http://$host:8080'),
          username: 'ager',
          password: 'p+w',
          client: server.client,
          cacheDirectory: cache,
        );

    String api(String host, [String query = '']) => '$host/player_api.php?username=ager&password=p%2Bw$query';

    test('adresse du serveur normalisée', () {
      expect(xtreamServer(' line.example.tv:8080 ').toString(), 'http://line.example.tv:8080');
      expect(xtreamServer('https://line.example.tv/').toString(), 'https://line.example.tv');
      expect(xtreamServer('http://line.example.tv/panel/?x=1').toString(), 'http://line.example.tv/panel');
      expect(xtreamServer('ftp://line.example.tv'), isNull);
    });

    test('compte : nombres en texte, refus et réponse illisible', () async {
      server.on(api('compte.tv'), '{"user_info":{"auth":1,"status":"Active","exp_date":"1793136060","is_trial":"1","max_connections":"1"}}');
      server.on(api('refus.tv'), '{"user_info":{"auth":0}}');
      server.on(api('html.tv'), '<html>Bienvenue</html>');
      final info = await client('compte.tv').accountInfo();
      expect(info.isActive, isTrue);
      expect(info.isTrial, isTrue);
      expect(info.maxConnections, 1);
      expect(info.expiresAt, DateTime.fromMillisecondsSinceEpoch(1793136060000));
      await expectLater(client('refus.tv').accountInfo(), throwsA(XtreamException.invalidCredentials));
      await expectLater(client('html.tv').accountInfo(), throwsA(XtreamException.badResponse));
    });

    test('direct : liens HLS, logos, identifiants du guide', () async {
      server.on(api('live.tv', '&action=get_live_categories'), '[{"category_id":"12","category_name":"FR| SPORTS"},{"category_id":13,"category_name":"CI| INFOS"}]');
      server.on(api('live.tv', '&action=get_live_streams&category_id=12'),
          '[{"name":"beIN 1","stream_id":101,"stream_icon":"http://img/bein.png","epg_channel_id":"bein1.fr"},{"name":"Sans icône","stream_id":"102","stream_icon":""}]');
      final categories = await client('live.tv').categories(ContentKind.live);
      expect(categories.map((c) => c.id), ['12', '13']);
      final channels = await client('live.tv').channels(ContentKind.live, categories.first);
      expect(channels.first.url, 'http://live.tv:8080/live/ager/p%2Bw/101.m3u8');
      expect(channels.first.streamId, '101');
      expect(channels.first.logoUrl, 'http://img/bein.png');
      expect(channels.last.logoUrl, isNull);
    });

    test('films : extension du conteneur, pas de guide', () async {
      server.on(api('vod.tv', '&action=get_vod_streams&category_id=5'), '[{"name":"Sissi","stream_id":7001,"container_extension":"mkv"},{"name":"Autre","stream_id":7002}]');
      final movies = await client('vod.tv').channels(ContentKind.movies, const XtreamCategory(id: '5', name: 'Films'));
      expect(movies.map((m) => m.url.split('/').last), ['7001.mkv', '7002.mp4']);
      expect(movies.first.streamId, isNull);
    });

    test('réponses vides tolérées', () async {
      server.on(api('vide.tv', '&action=get_series_categories'), '[]');
      server.on(api('vide.tv', '&action=get_vod_streams&category_id=1'), '{}');
      expect(await client('vide.tv').categories(ContentKind.series), isEmpty);
      expect(await client('vide.tv').channels(ContentKind.movies, const XtreamCategory(id: '1', name: 'A')), isEmpty);
    });

    test('série : épisodes regroupés par saison, objet ou tableau', () async {
      const show = XtreamSeries(id: '88', name: 'The Americans', coverUrl: 'http://img/am.jpg');
      server.on(api('serie.tv', '&action=get_series_info&series_id=88'),
          '{"info":{"plot":"Espions."},"episodes":{"2":[{"id":"9002","episode_num":"1","title":"S02E01","container_extension":"mkv","season":2}],'
          '"1":[{"id":"9013","episode_num":13,"title":"S01E13","info":{"duration":"00:52:10"}},{"id":"9001","episode_num":1,"title":"S01E01"}]}}');
      final detail = await client('serie.tv').seriesDetail(show);
      expect(detail.plot, 'Espions.');
      expect(detail.seasons.map((s) => s.number), [1, 2]);
      expect(detail.seasons.first.episodes.map((e) => e.title), ['S01E01', 'S01E13']);
      expect(detail.seasons.first.episodes.last.duration, '00:52:10');
      expect(detail.seasons.last.episodes.single.channel.url, 'http://serie.tv:8080/series/ager/p%2Bw/9002.mkv');

      server.on(api('liste.tv', '&action=get_series_info&series_id=5'),
          '{"episodes":[[{"id":"1","title":"Un","season":1}],[{"id":"2","title":"Deux","season":2}]]}');
      final list = await client('liste.tv').seriesDetail(const XtreamSeries(id: '5', name: 'Liste'));
      expect(list.seasons.map((s) => s.episodes.single.title), ['Un', 'Deux']);
    });

    test('guide : base64 décodé, émissions finies écartées', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      String b64(String text) => base64.encode(utf8.encode(text));
      server.on(api('epg.tv', '&action=get_short_epg&stream_id=55&limit=6'), jsonEncode({
        'epg_listings': [
          {'title': b64('Le 20 h'), 'description': b64('Journal du soir.'), 'start_timestamp': '${now + 3600}', 'stop_timestamp': '${now + 5400}'},
          {'title': b64('Fini'), 'start_timestamp': '${now - 7200}', 'stop_timestamp': '${now - 3600}'},
          {'title': 'Météo', 'description': '', 'start_timestamp': now - 600, 'stop_timestamp': now + 600},
        ],
      }));
      const channel = Channel(name: 'Info', url: 'http://epg.tv:8080/live/ager/p/55.m3u8', streamId: '55');
      final guide = await client('epg.tv').guide(channel);
      expect(guide.map((p) => p.title), ['Météo', 'Le 20 h']);
      expect(guide.first.isOnAir(), isTrue);
      expect(guide.first.summary, isNull);
      expect(guide.last.summary, 'Journal du soir.');
      expect(guide.first.progress(), inInclusiveRange(0.4, 0.6));
    });

    test('cache par compte, sans mot de passe dans les noms de fichier', () async {
      final key = api('cache.tv', '&action=get_vod_categories');
      server.on(key, '[{"category_id":"1","category_name":"Films"}]');
      final c = client('cache.tv');
      await c.categories(ContentKind.movies);
      await c.categories(ContentKind.movies);
      expect(server.calls[key], 1);
      await c.categories(ContentKind.movies, forceRefresh: true);
      expect(server.calls[key], 2);
      final names = cache.listSync(recursive: true).map((f) => f.path).join(' ');
      expect(names.contains('p+w') || names.contains('ager'), isFalse);
      await c.clearCache();
      await c.categories(ContentKind.movies);
      expect(server.calls[key], 3);
    });

    test('une erreur du serveur n’est pas mise en cache', () async {
      final key = api('panne.tv', '&action=get_live_categories');
      server.on(key, 'Service Unavailable', status: 503);
      final c = client('panne.tv');
      await expectLater(c.categories(ContentKind.live), throwsA(isA<XtreamException>()));
      server.on(key, '[{"category_id":"1","category_name":"Infos"}]');
      expect((await c.categories(ContentKind.live)).single.name, 'Infos');
    });
  });

  group('Bibliothèque', () {
    late FakeServer server;
    late Directory root;
    late MemoryPasswords passwords;
    setUp(() async {
      server = FakeServer();
      root = await Directory.systemTemp.createTemp('antenne-library');
      passwords = MemoryPasswords();
    });

    Future<Library> open() => Library.load(
          directory: Directory('${root.path}/data'),
          cacheDirectory: Directory('${root.path}/cache'),
          client: server.client,
          passwords: passwords,
        );

    const m3u = '#EXTM3U\n#EXTINF:-1 group-title="Infos",France 24\nhttps://a.example/f24.m3u8\n#EXTINF:-1,Sport 1\nhttps://a.example/s1.m3u8';

    test('un fichier importé survit au redémarrage', () async {
      final library = await open();
      final playlist = await library.addFile('Maison', 'liste.m3u', m3u);
      expect(playlist.channelCount, 2);
      final relaunched = await open();
      expect(relaunched.playlists.single.name, 'Maison');
      expect((await relaunched.channels(playlist.id)).map((c) => c.name), ['France 24', 'Sport 1']);
    });

    test('playlist sans chaîne refusée', () async {
      final library = await open();
      await expectLater(library.addFile('Vide', 'vide.m3u', '#EXTM3U\n'), throwsA(isA<LibraryException>()));
    });

    test('lien distant : téléchargement, actualisation, erreur HTTP', () async {
      server.on('a.example/liste.m3u?', m3u);
      server.on('a.example/expire.m3u?', 'Forbidden', status: 403);
      final library = await open();
      final playlist = await library.addRemote('Abonnement', 'https://a.example/liste.m3u');
      server.on('a.example/liste.m3u?', '$m3u\n#EXTINF:-1,Nouvelle\nhttps://a.example/n.m3u8');
      await library.refresh(playlist.id);
      expect(library.playlists.single.channelCount, 3);
      await expectLater(library.addRemote('Expiré', 'https://a.example/expire.m3u'), throwsA(isA<LibraryException>()));
    });

    test('compte : mot de passe hors du fichier, retiré à la suppression', () async {
      server.on('compte.tv/player_api.php?username=u&password=s3cr%2Bt', '{"user_info":{"auth":1,"status":"Active"}}');
      server.on('vieux.tv/player_api.php?username=u&password=p', '{"user_info":{"auth":"1","status":"Expired"}}');
      final library = await open();
      final account = await library.addXtream('Compte', Uri.parse('http://compte.tv'), 'u', 's3cr+t');
      expect(passwords.values[account.id], 's3cr+t');
      expect(await File('${root.path}/data/library.json').readAsString(), isNot(contains('s3cr')));
      expect((await library.xtreamClient(account.id))?.username, 'u');
      await library.delete(account.id);
      expect(passwords.values, isEmpty);
      await expectLater(library.addXtream('Vieux', Uri.parse('http://vieux.tv'), 'u', 'p'), throwsA(isA<LibraryException>()));
    });

    test('favoris et renommage persistants', () async {
      final library = await open();
      final playlist = await library.addFile('Maison', 'liste.m3u', m3u);
      final channel = (await library.channels(playlist.id)).first;
      await library.toggleFavorite(channel);
      await library.rename(playlist.id, '  Salon  ');
      final relaunched = await open();
      expect(relaunched.favorites.single.name, 'France 24');
      expect(relaunched.playlists.single.name, 'Salon');
      await relaunched.toggleFavorite(channel);
      expect((await open()).favorites, isEmpty);
    });

    test('reprise : règles et persistance', () async {
      final library = await open();
      const live = Channel(name: 'Direct', url: 'http://a.example/live/u/p/1.m3u8', streamId: '1');
      const film = Channel(name: 'Film', url: 'http://a.example/movie/u/p/9.mp4');
      await library.recordProgress(live, 300, double.infinity);
      await library.recordProgress(film, 4, 5000);
      expect(library.progress(live), isNull);
      expect(library.progress(film), isNull);
      await library.recordProgress(film, 600, 5000);
      expect((await open()).progress(film)?.resumePosition, 600);
      expect(const PlaybackProgress(position: 4900, duration: 5000).resumePosition, isNull);
      expect(const PlaybackProgress(position: 4900, duration: 5000).isFinished, isTrue);
    });
  });
}
