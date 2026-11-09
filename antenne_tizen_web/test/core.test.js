// Tests du cœur de l'app TV Samsung : node --test antenne_tizen_web/test
// Repris des tests de la version Android (antenne_android/test/core_test.dart).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../js/core.js');

test('M3U : attributs étendus', () => {
  const [channel] = core.parseM3u('#EXTM3U x-tvg-url="http://epg"\n' +
    '#EXTINF:-1 tvg-id="rti1.ci" tvg-name="RTI 1" tvg-logo="http://logo/rti1.png" group-title="Côte d\'Ivoire",RTI 1 HD\n' +
    'http://stream.example/live/rti1.m3u8');
  assert.equal(channel.name, 'RTI 1 HD');
  assert.equal(channel.logoUrl, 'http://logo/rti1.png');
  assert.equal(channel.group, "Côte d'Ivoire");
  assert.equal(channel.tvgId, 'rti1.ci');
});

test('M3U : une virgule entre guillemets ne coupe pas le titre', () => {
  const [channel] = core.parseM3u('#EXTINF:-1 group-title="Sport, Foot",Canal+ Sport, Afrique\nhttp://a.example/1.ts');
  assert.equal(channel.group, 'Sport, Foot');
  assert.equal(channel.name, 'Canal+ Sport, Afrique');
});

test('M3U : CRLF, BOM, lignes vides, groupe et agent', () => {
  const channels = core.parseM3u('﻿#EXTM3U\r\n\r\n#EXTINF:-1,Une\r\n#EXTGRP:Infos\r\n' +
    '#EXTVLCOPT:http-user-agent=Mozilla/5.0\r\nhttp://a.example/1\r\n#EXTINF:-1,Deux\r\nhttp://a.example/2\r\n');
  assert.deepEqual(channels.map((c) => c.name), ['Une', 'Deux']);
  assert.equal(channels[0].group, 'Infos');
  assert.equal(channels[0].userAgent, 'Mozilla/5.0');
  assert.equal(channels[1].group, undefined);
});

test('M3U : titre de secours et lignes invalides ignorées', () => {
  const channels = core.parseM3u('#EXTINF:-1 tvg-name="Nommée",\nhttp://a.example/1.m3u8\n' +
    '#EXTINF:-1,Cassée\npas une url\nhttp://a.example:8080/live/nue.m3u8?token=1');
  assert.deepEqual(channels.map((c) => c.name), ['Nommée', 'nue']);
});

test('M3U : groupes dans l’ordre d’apparition', () => {
  const groups = core.groupChannels(core.parseM3u('#EXTINF:-1 group-title="B",1\nhttp://a/1\n#EXTINF:-1,2\nhttp://a/2\n' +
    '#EXTINF:-1 group-title="A",3\nhttp://a/3\n#EXTINF:-1 group-title="B",4\nhttp://a/4'));
  assert.deepEqual(groups.map((g) => [g.name, g.channels.length]), [['B', 2], ['Sans groupe', 1], ['A', 1]]);
});

// Faux serveur : réponses par adresse exacte.
function fakeServer(routes) {
  const calls = [];
  const fetchFn = (url) => {
    calls.push(url);
    const [status, body] = routes[url] || [404, 'introuvable'];
    return Promise.resolve({ status, text: () => Promise.resolve(body) });
  };
  return { calls, fetchJson: core.jsonFetcher(fetchFn) };
}
const api = (host, query = '') => `http://${host}:8080/player_api.php?username=ager&password=p%2Bw${query}`;
const client = (host, server) => new core.XtreamClient(`http://${host}:8080`, 'ager', 'p+w', server.fetchJson);

test('Xtream : adresse du serveur normalisée', () => {
  assert.equal(core.xtreamServer(' line.example.tv:8080 '), 'http://line.example.tv:8080');
  assert.equal(core.xtreamServer('https://line.example.tv/'), 'https://line.example.tv');
  assert.equal(core.xtreamServer('http://line.example.tv/panel/?x=1'), 'http://line.example.tv/panel');
  assert.equal(core.xtreamServer('ftp://line.example.tv'), null);
  assert.equal(core.xtreamServer('  '), null);
});

test('Xtream : compte, nombres en texte, refus et réponse illisible', async () => {
  const server = fakeServer({
    [api('compte.tv')]: [200, '{"user_info":{"auth":1,"status":"Active","exp_date":"1793136060","is_trial":"1","max_connections":"1"}}'],
    [api('refus.tv')]: [200, '{"user_info":{"auth":0}}'],
    [api('html.tv')]: [200, '<html>Bienvenue</html>'],
    [api('panne.tv')]: [503, 'Service Unavailable'],
  });
  const info = await client('compte.tv', server).accountInfo();
  assert.equal(info.status, 'Active');
  assert.equal(info.isTrial, true);
  assert.equal(info.maxConnections, 1);
  assert.equal(info.expiresAt.getTime(), 1793136060000);
  await assert.rejects(client('refus.tv', server).accountInfo(), /refusé par le serveur/);
  await assert.rejects(client('html.tv', server).accountInfo(), /illisible/);
  await assert.rejects(client('panne.tv', server).accountInfo(), /code 503/);
});

test('Xtream : direct, liens HLS, logos, identifiants', async () => {
  const server = fakeServer({
    [api('live.tv', '&action=get_live_categories')]: [200, '[{"category_id":"12","category_name":"FR| SPORTS"},{"category_id":13,"category_name":"CI| INFOS"}]'],
    [api('live.tv', '&action=get_live_streams&category_id=12')]: [200,
      '[{"name":"beIN 1","stream_id":101,"stream_icon":"http://img/bein.png"},{"name":"Sans icône","stream_id":"102","stream_icon":""}]'],
  });
  const categories = await client('live.tv', server).categories('live');
  assert.deepEqual(categories.map((c) => c.id), ['12', '13']);
  const channels = await client('live.tv', server).channels('live', categories[0]);
  assert.equal(channels[0].url, 'http://live.tv:8080/live/ager/p%2Bw/101.ts');
  assert.equal(channels[0].fallbackUrl, 'http://live.tv:8080/live/ager/p%2Bw/101.m3u8');
  assert.equal(channels[0].streamId, '101');
  assert.equal(channels[0].logoUrl, 'http://img/bein.png');
  assert.equal(channels[1].logoUrl, undefined);
  assert.equal(channels[1].group, 'FR| SPORTS');
});

test('Xtream : films avec l’extension du conteneur', async () => {
  const server = fakeServer({
    [api('vod.tv', '&action=get_vod_streams&category_id=5')]: [200, '[{"name":"Sissi","stream_id":7001,"container_extension":"mkv"},{"name":"Autre","stream_id":7002}]'],
  });
  const movies = await client('vod.tv', server).channels('movies', { id: '5', name: 'Films' });
  assert.deepEqual(movies.map((m) => m.url.split('/').pop()), ['7001.mkv', '7002.mp4']);
  assert.equal(movies[0].streamId, undefined);
});

test('Xtream : réponses vides tolérées', async () => {
  const server = fakeServer({
    [api('vide.tv', '&action=get_vod_categories')]: [200, '[]'],
    [api('vide.tv', '&action=get_vod_streams&category_id=1')]: [200, '{}'],
  });
  assert.deepEqual(await client('vide.tv', server).categories('movies'), []);
  assert.deepEqual(await client('vide.tv', server).channels('movies', { id: '1', name: 'A' }), []);
});

test('les liens sont masqués dans les messages d’erreur', () => {
  assert.equal(core.hideLinks('Échec : http://h.tv/live/ager/secret/1.m3u8 (code 5)'), 'Échec : [lien] (code 5)');
});

test('Xtream : toutes les chaînes, avec le nom de leur catégorie', async () => {
  const server = fakeServer({
    [api('tout.tv', '&action=get_live_categories')]: [200, '[{"category_id":"12","category_name":"CI| INFOS"}]'],
    [api('tout.tv', '&action=get_live_streams')]: [200, '[{"name":"RTI 1","stream_id":1,"category_id":"12"},{"name":"Autre","stream_id":2,"category_id":"99"}]'],
  });
  const all = await client('tout.tv', server).allChannels('live');
  assert.deepEqual(all.map((c) => [c.name, c.group]), [['RTI 1', 'CI| INFOS'], ['Autre', undefined]]);
  assert.equal(all[0].url, 'http://tout.tv:8080/live/ager/p%2Bw/1.ts');
});

test('recherche : accents, casse, mots dans le désordre, début du nom d’abord', () => {
  const channels = ['Canal+ Sport', 'beIN Sports 1', 'Télé Sport Côte d’Ivoire', 'Sport 24', 'Novelas'].map((name) => ({ name }));
  assert.deepEqual(core.search(channels, 'SPORT').map((c) => c.name), ['Sport 24', 'Canal+ Sport', 'beIN Sports 1', 'Télé Sport Côte d’Ivoire']);
  assert.deepEqual(core.search(channels, 'ivoire tele').map((c) => c.name), ['Télé Sport Côte d’Ivoire']);
  assert.deepEqual(core.search(channels, '   '), []);
  assert.equal(core.search(channels, 's', 2).length, 2);
});

test('Xtream : guide, base64 décodé, émissions finies écartées', async () => {
  const now = 1793136000000;
  const s = now / 1000;
  const b64 = (t) => Buffer.from(t, 'utf8').toString('base64');
  const server = fakeServer({
    [api('epg.tv', '&action=get_short_epg&stream_id=55&limit=4')]: [200, JSON.stringify({ epg_listings: [
      { title: b64('Le 20 h'), description: b64('Journal du soir.'), start_timestamp: String(s + 3600), stop_timestamp: String(s + 5400) },
      { title: b64('Fini'), start_timestamp: String(s - 7200), stop_timestamp: String(s - 3600) },
      { title: 'Météo', description: '', start_timestamp: s - 600, stop_timestamp: s + 600 },
    ] })],
  });
  const guide = await client('epg.tv', server).guide({ streamId: '55' }, 4, now);
  assert.deepEqual(guide.map((p) => p.title), ['Météo', 'Le 20 h']);
  assert.equal(guide[0].summary, null);
  assert.equal(guide[1].summary, 'Journal du soir.');
  assert.equal(guide[0].start, now - 600000);
  assert.deepEqual(await client('epg.tv', server).guide({ name: 'Film' }), []);
});

test('stockage : anciens liens HLS du direct convertis en MPEG-TS, une seule chaîne pour les deux formes', () => {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const old = { playlists: [], history: [], progress: {},
    favorites: [{ name: 'RTI 1', url: 'http://h.tv:8080/live/u/p/7.m3u8', streamId: '7', live: true, playlistId: 'x' }] };
  const data = { 'antenne.v1': JSON.stringify(old) };
  const sandbox = { localStorage: { getItem: (k) => data[k] ?? null, setItem: (k, v) => { data[k] = v; } } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../js/store.js'), 'utf8'), sandbox);
  const store = sandbox.AntenneStore;
  assert.equal(store.favorites()[0].url, 'http://h.tv:8080/live/u/p/7.ts');
  assert.equal(store.favorites()[0].fallbackUrl, 'http://h.tv:8080/live/u/p/7.m3u8');
  assert.equal(store.isFavorite({ url: 'http://h.tv:8080/live/u/p/7.ts' }), true);
  assert.equal(store.isFavorite({ url: 'http://h.tv:8080/live/u/p/7.m3u8' }), true);
  store.recordWatched({ name: 'RTI 1', url: 'http://h.tv:8080/live/u/p/7.m3u8', live: true });
  store.recordWatched({ name: 'RTI 1', url: 'http://h.tv:8080/live/u/p/7.ts', live: true });
  assert.equal(store.history().length, 1);
  assert.equal(store.isFavorite({ url: 'http://autre.tv/live/u/p/7.m3u8' }), false);
});
