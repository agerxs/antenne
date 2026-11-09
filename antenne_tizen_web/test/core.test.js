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
  assert.equal(channels[0].url, 'http://live.tv:8080/live/ager/p%2Bw/101.m3u8');
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
