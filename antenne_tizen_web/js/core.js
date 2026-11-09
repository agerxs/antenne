// Cœur d'Antenne pour les téléviseurs Samsung : lecture des playlists M3U et des comptes Xtream.
// Portage de antenne_android/lib/core (m3u_parser.dart, xtream.dart), sans dépendance au navigateur
// pour pouvoir le tester avec Node (test/core.test.js).
(function (root) {
  'use strict';

  // ---------- M3U ----------

  var ATTRIBUTE = /([A-Za-z0-9_-]+)="([^"]*)"/g;

  function blankToNull(value) {
    if (value == null) return null;
    var trimmed = String(value).trim();
    return trimmed === '' ? null : trimmed;
  }

  function after(prefix, line) {
    if (line.length < prefix.length || line.slice(0, prefix.length).toUpperCase() !== prefix.toUpperCase()) return null;
    return line.slice(prefix.length).trim();
  }

  function parseUrl(text) {
    var match = /^([a-z][a-z0-9+.-]*):\/\/([^/?#:]+)/i.exec(text);
    if (!match) return null;
    var path = text.slice(match[0].length).split(/[?#]/)[0];
    var port = /^:\d+/.exec(path);
    if (port) path = path.slice(port[0].length);
    return { host: match[2], segments: path.split('/').filter(Boolean) };
  }

  /** Lit les playlists M3U / M3U8 « étendues » des fournisseurs IPTV. */
  function parseM3u(content) {
    var channels = [];
    var pending = newPending();
    var lines = content.split(/\r\n|\r|\n/);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.charAt(0) === '﻿') line = line.slice(1);
      if (line === '') continue;

      if (line.charAt(0) === '#') {
        var extinf = after('#EXTINF:', line);
        var group = after('#EXTGRP:', line);
        var option = after('#EXTVLCOPT:', line);
        if (extinf != null) {
          applyExtinf(pending, extinf);
        } else if (group != null && pending.group == null) {
          pending.group = blankToNull(group);
        } else if (option != null) {
          var agent = after('http-user-agent=', option);
          if (agent != null) pending.userAgent = blankToNull(agent);
        }
        continue;
      }

      var url = parseUrl(line);
      if (url && url.host) channels.push(toChannel(pending, line, url));
      pending = newPending();
    }
    return channels;
  }

  function newPending() {
    return { title: null, attributes: {}, group: null, userAgent: null };
  }

  function applyExtinf(pending, body) {
    // Le titre suit la première virgule hors guillemets : les attributs peuvent en contenir.
    var inQuotes = false;
    var comma = -1;
    for (var i = 0; i < body.length; i++) {
      var c = body.charAt(i);
      if (c === '"') inQuotes = !inQuotes;
      else if (c === ',' && !inQuotes) { comma = i; break; }
    }
    var head = comma >= 0 ? body.slice(0, comma) : body;
    if (comma >= 0) pending.title = blankToNull(body.slice(comma + 1));
    var match;
    ATTRIBUTE.lastIndex = 0;
    while ((match = ATTRIBUTE.exec(head)) !== null) pending.attributes[match[1].toLowerCase()] = match[2];
  }

  function toChannel(pending, line, url) {
    var last = url.segments.length ? url.segments[url.segments.length - 1].split('.')[0] : null;
    var channel = {
      name: pending.title || blankToNull(pending.attributes['tvg-name']) || blankToNull(last) || 'Chaîne sans nom',
      url: line,
    };
    var logo = blankToNull(pending.attributes['tvg-logo']);
    var group = blankToNull(pending.attributes['group-title']) || pending.group;
    var tvgId = blankToNull(pending.attributes['tvg-id']);
    if (logo) channel.logoUrl = logo;
    if (group) channel.group = group;
    if (tvgId) channel.tvgId = tvgId;
    if (pending.userAgent) channel.userAgent = pending.userAgent;
    return channel;
  }

  /** Regroupe les chaînes d'une playlist M3U par groupe, dans l'ordre d'apparition. */
  function groupChannels(channels) {
    var groups = [];
    var byName = {};
    channels.forEach(function (channel) {
      var name = channel.group || 'Sans groupe';
      if (!byName[name]) {
        byName[name] = { id: name, name: name, channels: [] };
        groups.push(byName[name]);
      }
      byName[name].channels.push(channel);
    });
    return groups;
  }

  // ---------- Xtream ----------

  function XtreamError(message) {
    this.name = 'XtreamError';
    this.message = message;
  }
  XtreamError.prototype = Object.create(Error.prototype);
  XtreamError.invalidCredentials = function () { return new XtreamError('Utilisateur ou mot de passe refusé par le serveur.'); };
  XtreamError.badResponse = function () {
    return new XtreamError("Le serveur a répondu quelque chose d'illisible. Vérifie l'adresse du serveur.");
  };
  XtreamError.http = function (code) { return new XtreamError('Le serveur a refusé la demande (code ' + code + ').'); };

  /** Accepte « serveur.com:8080 » comme « http://serveur.com:8080/ ». Renvoie l'adresse normalisée, sans « / » final. */
  function xtreamServer(input) {
    var text = String(input || '').trim();
    if (text === '') return null;
    if (text.indexOf('://') < 0) text = 'http://' + text;
    var match = /^(https?):\/\/([^/?#:\s]+)(:\d+)?(\/[^?#]*)?/i.exec(text);
    if (!match) return null;
    var path = (match[4] || '').replace(/^\/+|\/+$/g, '');
    return match[1].toLowerCase() + '://' + match[2] + (match[3] || '') + (path ? '/' + path : '');
  }

  // Lecture tolérante du JSON (nombres en texte, champs nuls, objets vides…)

  function records(json) {
    if (Array.isArray(json)) return json.filter(isObject);
    if (isObject(json)) return Object.keys(json).map(function (k) { return json[k]; }).filter(isObject);
    return [];
  }
  function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
  function text(value) {
    if (typeof value === 'string') return value.trim() === '' ? null : value.trim();
    if (typeof value === 'number' && isFinite(value)) return String(value === Math.round(value) ? Math.round(value) : value);
    return null;
  }
  function int(value) {
    if (typeof value === 'number') return Math.trunc(value);
    if (typeof value === 'boolean') return value ? 1 : 0;
    if (typeof value === 'string' && /^\s*-?\d+\s*$/.test(value)) return parseInt(value, 10);
    return null;
  }
  function num(value) {
    if (typeof value === 'number') return value;
    if (typeof value === 'string' && value.trim() !== '' && isFinite(Number(value))) return Number(value);
    return null;
  }

  /** « + » serait lu comme une espace par la plupart des serveurs. */
  function encode(value) { return encodeURIComponent(value); }

  /**
   * Interroge `player_api.php` catégorie par catégorie, au lieu de la playlist complète
   * (plusieurs centaines de milliers d'entrées chez certains fournisseurs).
   * `fetchJson(url)` est fourni par l'appelant : il renvoie une promesse du JSON décodé.
   */
  function XtreamClient(server, username, password, fetchJson) {
    this.server = server;
    this.username = username;
    this.password = password;
    this.fetchJson = fetchJson;
  }

  XtreamClient.prototype.endpoint = function (action, extra) {
    var query = 'username=' + encode(this.username) + '&password=' + encode(this.password);
    if (action) query += '&action=' + encode(action);
    Object.keys(extra || {}).forEach(function (key) { query += '&' + key + '=' + encode(extra[key]); });
    return this.server + '/player_api.php?' + query;
  };

  XtreamClient.prototype.streamUrl = function (kind, id, extension) {
    return this.server + '/' + kind + '/' + encodeURIComponent(this.username) + '/' + encodeURIComponent(this.password) +
      '/' + id + '.' + extension;
  };

  XtreamClient.prototype.load = function (action, extra) {
    return this.fetchJson(this.endpoint(action, extra));
  };

  XtreamClient.prototype.accountInfo = function () {
    return this.load(null).then(function (json) {
      var info = isObject(json) ? json.user_info : null;
      if (!isObject(info)) throw XtreamError.badResponse();
      if (int(info.auth) === 0) throw XtreamError.invalidCredentials();
      var expiry = num(info.exp_date);
      return {
        status: text(info.status) || '?',
        isTrial: int(info.is_trial) === 1,
        expiresAt: expiry == null ? null : new Date(expiry * 1000),
        maxConnections: int(info.max_connections),
      };
    });
  };

  var CATEGORY_ACTIONS = { live: 'get_live_categories', movies: 'get_vod_categories' };

  /** kind : « live » (direct) ou « movies » (films). */
  XtreamClient.prototype.categories = function (kind) {
    return this.load(CATEGORY_ACTIONS[kind]).then(function (json) {
      return records(json).reduce(function (list, record) {
        var id = text(record.category_id);
        if (id != null) list.push({ id: id, name: text(record.category_name) || 'Sans nom' });
        return list;
      }, []);
    });
  };

  /** Chaînes en direct ou films d'une catégorie, prêts à lire. */
  XtreamClient.prototype.channels = function (kind, category) {
    var self = this;
    var action = kind === 'live' ? 'get_live_streams' : 'get_vod_streams';
    return this.load(action, { category_id: category.id }).then(function (json) {
      return records(json).reduce(function (list, record) {
        var id = text(record.stream_id);
        if (id == null) return list;
        var channel = {
          name: text(record.name) || 'Sans nom',
          url: kind === 'live'
            ? self.streamUrl('live', id, 'm3u8')
            : self.streamUrl('movie', id, text(record.container_extension) || 'mp4'),
          group: category.name,
        };
        var logo = text(record.stream_icon);
        if (logo) channel.logoUrl = logo;
        if (kind === 'live') channel.streamId = id;
        list.push(channel);
        return list;
      }, []);
    });
  };

  /**
   * Fabrique le `fetchJson` d'un XtreamClient à partir d'une fonction de type `fetch`
   * (celle du navigateur, ou un faux serveur dans les tests).
   */
  function jsonFetcher(fetchFn) {
    return function (url) {
      return fetchFn(url).then(function (response) {
        if (response.status < 200 || response.status >= 300) throw XtreamError.http(response.status);
        return response.text();
      }).then(function (body) {
        try {
          return JSON.parse(body);
        } catch (e) {
          throw XtreamError.badResponse();
        }
      });
    };
  }

  /** Masque les liens d'un message d'erreur : ceux d'un compte Xtream contiennent le mot de passe. */
  function hideLinks(message) {
    return String(message).replace(/\w+:\/\/\S+/g, '[lien]');
  }

  var api = {
    parseM3u: parseM3u,
    groupChannels: groupChannels,
    xtreamServer: xtreamServer,
    XtreamClient: XtreamClient,
    XtreamError: XtreamError,
    jsonFetcher: jsonFetcher,
    hideLinks: hideLinks,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.AntenneCore = api;
})(this);
