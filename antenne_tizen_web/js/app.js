// Antenne sur téléviseur Samsung : accueil, ajout d'une playlist, navigation, lecture.
// Tout se pilote aux flèches, OK et Retour de la télécommande.
(function () {
  'use strict';

  var core = window.AntenneCore;
  var store = window.AntenneStore;
  var appEl = document.getElementById('app');
  var osdEl = document.getElementById('osd');

  var KEY = {
    LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, ENTER: 13, BACK: 10009,
    IME_DONE: 65376, IME_CANCEL: 65385,
    PLAY_PAUSE: 10252, PLAY: 415, PAUSE: 19, STOP: 413, FAST_FORWARD: 417, REWIND: 412,
    CHANNEL_UP: 427, CHANNEL_DOWN: 428,
    LONG_ENTER: -13, // appui long sur OK (voir le gestionnaire de clavier)
  };

  try {
    window.tizen.tvinputdevice.registerKeyBatch(['MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop',
      'MediaFastForward', 'MediaRewind', 'ChannelUp', 'ChannelDown']);
  } catch (e) {
    // Hors téléviseur (navigateur de test) : flèches, Entrée et Échap suffisent.
  }

  var ICON = {
    plus: '<svg class="icon" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    list: '<svg class="icon" viewBox="0 0 24 24"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>',
    account: '<svg class="icon" viewBox="0 0 24 24"><rect x="2" y="7" width="20" height="14" rx="2"/><path d="M17 2l-5 5-5-5"/></svg>',
    search: '<svg class="icon" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.35-4.35"/></svg>',
    settings: '<svg class="icon" viewBox="0 0 24 24"><path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/></svg>',
    star: '<svg class="icon star" viewBox="0 0 24 24"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01z"/></svg>',
  };

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  var toastEl = document.getElementById('toast');
  var toastTimer = null;
  function toast(message) {
    toastEl.textContent = message;
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.hidden = true; }, 2500);
  }

  function toggleFavorite(channel) {
    toast(store.toggleFavorite(channel) ? 'Ajouté aux favoris' : 'Retiré des favoris');
  }

  function hostOf(url) {
    var match = /^\w+:\/\/([^/:?#]+)/.exec(url || '');
    return match ? match[1] : url;
  }

  function header(crumb, hint) {
    return '<div class="top"><div class="wordmark">Ant<b>e</b>nne</div>' +
      (crumb ? '<div class="crumb">' + esc(crumb) + '</div>' : '') +
      (hint ? '<div class="hint">' + esc(hint) + '</div>' : '') + '</div>';
  }

  /** Tranche visible d'une longue liste, centrée sur l'élément sélectionné. */
  function windowOf(length, index, visible) {
    var start = Math.max(0, Math.min(index - Math.floor(visible / 2), length - visible));
    return { start: start, end: Math.min(length, start + visible) };
  }

  // ---------- Réseau ----------

  function fetchWithTimeout(url, ms) {
    var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    var timer = setTimeout(function () { if (controller) controller.abort(); }, ms || 30000);
    return fetch(url, controller ? { signal: controller.signal } : {}).then(function (response) {
      clearTimeout(timer);
      return response;
    }, function () {
      clearTimeout(timer);
      throw new Error(controller && controller.signal.aborted ? 'Le serveur ne répond pas.' : 'Connexion impossible au serveur.');
    });
  }

  var fetchJson = core.jsonFetcher(function (url) { return fetchWithTimeout(url, 30000); });

  function loadM3u(url) {
    return fetchWithTimeout(url, 90000).then(function (response) {
      if (response.status < 200 || response.status >= 300) throw new Error('Le serveur a refusé la playlist (code ' + response.status + ').');
      return response.text();
    }).then(function (body) {
      var channels = core.parseM3u(body);
      if (!channels.length) throw new Error('Aucune chaîne trouvée à cette adresse.');
      return channels;
    });
  }

  var VOD = /\.(mp4|mkv|avi|mov|m4v|webm)(\?|$)/i;

  /** Accès uniforme au contenu d'une playlist, gardé en mémoire le temps de la session. */
  var sources = {};

  function sourceFor(playlist, preloaded) {
    if (sources[playlist.id]) return sources[playlist.id];
    var source;
    if (playlist.kind === 'xtream') {
      var client = new core.XtreamClient(playlist.server, playlist.username, playlist.password, fetchJson);
      var everything = {};
      var guides = {};
      source = {
        everything: function (section) {
          if (!everything[section]) {
            everything[section] = client.allChannels(section).then(function (list) {
              list.forEach(function (channel) { channel.live = section === 'live'; channel.playlistId = playlist.id; });
              return list;
            });
            everything[section].catch(function () { delete everything[section]; });
          }
          return everything[section];
        },
        guide: function (channel) {
          var key = channel.streamId;
          var cached = guides[key];
          if (cached && Date.now() - cached.at < 5 * 60000) return cached.promise;
          var promise = client.guide(channel, 4);
          guides[key] = { at: Date.now(), promise: promise };
          promise.catch(function () { delete guides[key]; });
          return promise;
        },
        sections: [{ id: 'live', name: 'Direct' }, { id: 'movies', name: 'Films' }],
        categories: function (section) { return client.categories(section); },
        channels: function (section, category) {
          return client.channels(section, category).then(function (list) {
            list.forEach(function (channel) { channel.live = section === 'live'; channel.playlistId = playlist.id; });
            return list;
          });
        },
      };
    } else {
      var groups = null;
      source = {
        sections: null,
        categories: function () {
          if (!groups) {
            groups = (preloaded ? Promise.resolve(preloaded) : loadM3u(playlist.url)).then(function (channels) {
              channels.forEach(function (channel) { channel.live = !VOD.test(channel.url); channel.playlistId = playlist.id; });
              return core.groupChannels(channels);
            });
            groups.catch(function () { groups = null; });
          }
          return groups;
        },
        channels: function (section, category) { return Promise.resolve(category.channels); },
        everything: function () {
          return source.categories().then(function (list) {
            return list.reduce(function (all, group) { return all.concat(group.channels); }, []);
          });
        },
      };
    }
    sources[playlist.id] = source;
    return source;
  }

  /** Émissions en cours et à venir d'une chaîne (comptes Xtream seulement), ou liste vide. */
  function guideFor(channel) {
    var playlist = channel && channel.live && channel.streamId && store.find(channel.playlistId);
    if (!playlist) return Promise.resolve([]);
    var source = sourceFor(playlist);
    return source.guide ? source.guide(channel).catch(function () { return []; }) : Promise.resolve([]);
  }

  function hm(ms) {
    var d = new Date(ms);
    return d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
  }

  /** « Maintenant » et « Ensuite » d'une chaîne, en HTML. */
  function guideHtml(programmes) {
    var now = Date.now();
    var current = programmes.filter(function (p) { return p.start <= now && now < p.end; })[0];
    var next = programmes.filter(function (p) { return p.start > now; })[0];
    var html = '';
    if (current) {
      html += '<div class="now"><span class="when">' + hm(current.start) + ' – ' + hm(current.end) + '</span>' + esc(current.title) + '</div>' +
        '<div class="progress"><i style="width:' + ((now - current.start) / (current.end - current.start) * 100).toFixed(1) + '%"></i></div>';
      if (current.summary) html += '<div class="summary">' + esc(current.summary) + '</div>';
    }
    if (next) html += '<div class="next"><span class="when">' + hm(next.start) + '</span>' + esc(next.title) + '</div>';
    return html;
  }

  // ---------- Écrans ----------

  var screen = null;
  function show(next) {
    var previous = screen;
    // En quittant un écran avec aperçu (sauf pour le plein écran), on coupe la lecture.
    if (previous && previous.usesPreview && previous !== next && !(next instanceof PlayerScreen)) player.stop();
    screen = next;
    document.body.classList.toggle('preview', !!next.usesPreview);
    screen.render();
  }

  function exitApp() {
    try { window.tizen.application.getCurrentApplication().exit(); } catch (e) { /* navigateur de test */ }
  }

  // Accueil : reprendre, chaînes récentes, favoris, playlists. Une rangée de cartes par sujet,
  // haut et bas pour changer de rangée, gauche et droite pour parcourir.
  var SHELF_HEIGHT = { hero: 330, channel: 318, playlist: 222 };
  var VIEWPORT = 860;

  function initials(name) {
    var words = String(name || '').replace(/[^\p{L}\p{N} ]/gu, ' ').trim().split(/\s+/).filter(Boolean);
    return ((words[0] || '?').charAt(0) + (words[1] ? words[1].charAt(0) : (words[0] || '').charAt(1))).toUpperCase();
  }

  function tile(channel, extraClass) {
    return '<div class="tile' + (extraClass ? ' ' + extraClass : '') + '">' +
      (channel.logoUrl ? '<img src="' + esc(channel.logoUrl) + '" onerror="this.remove()">' : '') +
      '<span class="monogram">' + esc(initials(channel.name)) + '</span></div>';
  }

  function progressBar(channel) {
    var fraction = store.watchedFraction(channel);
    return fraction > 0 ? '<div class="progress"><i style="width:' + (fraction * 100).toFixed(1) + '%"></i></div>' : '';
  }

  function nowText() {
    var d = new Date();
    return d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
  }

  function HomeScreen() {
    this.row = 0;
    this.cols = {};
  }

  HomeScreen.prototype.shelves = function () {
    var history = store.history();
    var favorites = store.favorites();
    var playlists = store.playlists();
    var shelves = [];
    if (history.length) shelves.push({ id: 'resume', title: 'Reprendre', kind: 'hero', items: [history[0]], zap: history, offset: 0 });
    if (history.length > 1) shelves.push({ id: 'recent', title: 'Regardé récemment', kind: 'channel', items: history.slice(1), zap: history, offset: 1 });
    if (favorites.length) shelves.push({ id: 'favorites', title: 'Favoris', kind: 'channel', items: favorites, zap: favorites, offset: 0 });
    var cards = playlists.map(function (p) { return { playlist: p }; }).concat([{ add: true }]);
    if (playlists.length) cards.push({ manage: true });
    shelves.push({ id: 'playlists', title: 'Playlists', kind: 'playlist', items: cards });
    return shelves;
  };

  HomeScreen.prototype.render = function () {
    var self = this;
    var shelves = this.shelves();
    this.row = Math.min(this.row, shelves.length - 1);
    var html = '<div class="home-top"><div class="wordmark">Ant<b>e</b>nne</div><div class="clock">' + nowText() + '</div></div>';
    if (!store.playlists().length) {
      html += '<p class="intro">Ajoute une playlist pour commencer : un compte Xtream (serveur, utilisateur et mot de passe ' +
        'donnés par ton fournisseur) ou un lien M3U.</p>';
    }

    // Décalage vertical : la rangée active reste entièrement visible.
    var top = 0;
    for (var r = 0; r < this.row; r++) top += SHELF_HEIGHT[shelves[r].kind];
    var shift = Math.max(0, top + SHELF_HEIGHT[shelves[this.row].kind] - VIEWPORT);
    html += '<div class="shelves" style="transform:translateY(-' + shift + 'px)">';

    shelves.forEach(function (shelf, r) {
      var active = r === self.row;
      var col = Math.min(self.cols[shelf.id] || 0, shelf.items.length - 1);
      self.cols[shelf.id] = col;
      html += '<section class="shelf ' + shelf.kind + (active ? ' active' : '') + '"><h2>' + esc(shelf.title) + '</h2>' +
        '<div class="track" style="transform:translateX(-' + self.trackShift(shelf, col) + 'px)">';
      shelf.items.forEach(function (item, c) {
        var focus = active && c === col ? ' focus' : '';
        if (shelf.kind === 'hero') {
          var sub = item.live ? 'Direct' : (store.resumePosition(item) ? 'Reprendre à ' + clock(store.resumePosition(item)) : 'Film');
          html += '<div class="card hero' + focus + '">' + tile(item, 'large') + '<div class="text"><div class="name">' + esc(item.name) +
            '</div><div class="meta">' + esc([item.group, sub].filter(Boolean).join(' · ')) + '</div>' + progressBar(item) + '</div></div>';
        } else if (shelf.kind === 'channel') {
          html += '<div class="card channel' + focus + '">' + tile(item) + '<div class="name">' + esc(item.name) + '</div>' + progressBar(item) + '</div>';
        } else if (item.playlist) {
          var p = item.playlist;
          var meta = p.kind === 'xtream' ? 'Compte · ' + hostOf(p.server) : 'Lien M3U' + (p.channelCount ? ' · ' + p.channelCount + ' chaînes' : '');
          html += '<div class="card playlist' + focus + '">' + (p.kind === 'xtream' ? ICON.account : ICON.list) +
            '<div class="text"><div class="name">' + esc(p.name) + '</div><div class="meta">' + esc(meta) + '</div></div></div>';
        } else {
          html += '<div class="card playlist quiet' + focus + '">' + (item.add ? ICON.plus : ICON.settings) +
            '<div class="text"><div class="name">' + (item.add ? 'Ajouter une playlist' : 'Gérer les playlists') + '</div></div></div>';
        }
      });
      html += '</div></section>';
    });
    appEl.innerHTML = html + '</div>';

    clearTimeout(this.clockTimer);
    this.clockTimer = setTimeout(function () { if (screen === self) self.render(); }, 30000);
  };

  /** Décalage horizontal d'une rangée : la carte sélectionnée reste visible, avec une carte de contexte avant elle. */
  HomeScreen.prototype.trackShift = function (shelf, col) {
    var width = { hero: 0, channel: 304, playlist: 444 }[shelf.kind];
    var visible = { hero: 1, channel: 5, playlist: 3 }[shelf.kind];
    if (!width || shelf.items.length <= visible) return 0;
    return Math.max(0, Math.min(col - 1, shelf.items.length - visible)) * width;
  };

  HomeScreen.prototype.key = function (key) {
    var shelves = this.shelves();
    var shelf = shelves[this.row];
    var col = this.cols[shelf.id] || 0;
    switch (key) {
      case KEY.UP:
      case KEY.DOWN:
        this.row = Math.max(0, Math.min(shelves.length - 1, this.row + (key === KEY.UP ? -1 : 1)));
        break;
      case KEY.LEFT:
      case KEY.RIGHT:
        this.cols[shelf.id] = Math.max(0, Math.min(shelf.items.length - 1, col + (key === KEY.LEFT ? -1 : 1)));
        break;
      case KEY.LONG_ENTER:
        if (shelf.kind === 'playlist') return true;
        toggleFavorite(shelf.items[col]);
        break;
      case KEY.ENTER:
      case KEY.PLAY:
      case KEY.PLAY_PAUSE:
        var item = shelf.items[col];
        if (shelf.kind !== 'playlist') return show(new PlayerScreen(this, shelf.zap, col + shelf.offset)), true;
        if (item.add) return show(new AddScreen()), true;
        if (item.manage) return show(new ManageScreen()), true;
        store.setLastPlaylist(item.playlist.id);
        return show(new BrowseScreen(item.playlist)), true;
      case KEY.BACK:
        exitApp();
        return true;
      default:
        return false;
    }
    this.render();
    return true;
  };

  /** Retour du lecteur : on revient sur « Reprendre », qui montre ce qu'on vient de regarder. */
  HomeScreen.prototype.afterPlayback = function () {
    this.row = 0;
    this.cols = {};
  };

  // Gestion des playlists : supprimer celles dont on ne veut plus.
  function ManageScreen() {
    this.index = 0;
    this.confirm = false;
  }

  ManageScreen.prototype.render = function () {
    var self = this;
    var playlists = store.playlists();
    var html = header('Gérer les playlists', 'OK : supprimer    Retour : accueil') + '<div class="home-list">';
    playlists.forEach(function (playlist, i) {
      var focused = i === self.index;
      html += '<div class="row' + (focused ? ' focus' : '') + '">' + (playlist.kind === 'xtream' ? ICON.account : ICON.list) +
        '<span class="label">' + esc(playlist.name) + '</span>' +
        (focused ? '<span class="action focus">' + (self.confirm ? 'OK encore pour confirmer la suppression' : 'Supprimer') + '</span>' : '') + '</div>';
    });
    appEl.innerHTML = html + '</div>';
  };

  ManageScreen.prototype.key = function (key) {
    var playlists = store.playlists();
    switch (key) {
      case KEY.UP:
      case KEY.DOWN:
        this.index = Math.max(0, Math.min(playlists.length - 1, this.index + (key === KEY.UP ? -1 : 1)));
        this.confirm = false;
        break;
      case KEY.ENTER:
        if (!this.confirm) {
          this.confirm = true;
        } else {
          delete sources[playlists[this.index].id];
          store.remove(playlists[this.index].id);
          this.confirm = false;
          if (store.playlists().length === 0) return show(new HomeScreen()), true;
          this.index = Math.min(this.index, store.playlists().length - 1);
        }
        break;
      case KEY.BACK:
        show(new HomeScreen());
        return true;
      default:
        return false;
    }
    this.render();
    return true;
  };

  // Ajout d'une playlist : compte Xtream ou lien M3U.
  var FIELDS = {
    xtream: [
      { key: 'server', label: 'Serveur', placeholder: 'serveur.com:8080' },
      { key: 'username', label: 'Utilisateur' },
      { key: 'password', label: 'Mot de passe', type: 'password' },
      { key: 'name', label: 'Nom (facultatif)' },
    ],
    remote: [
      { key: 'url', label: 'Lien M3U', placeholder: 'http://…/playlist.m3u' },
      { key: 'name', label: 'Nom (facultatif)' },
    ],
  };

  function AddScreen() {
    this.mode = 'xtream';
    this.row = 1;
    this.values = {};
    this.message = '';
    this.error = false;
    this.busy = false;
  }

  AddScreen.prototype.rows = function () {
    return ['tabs'].concat(FIELDS[this.mode].map(function (f) { return f.key; }), ['submit']);
  };

  AddScreen.prototype.render = function () {
    var self = this;
    var rows = this.rows();
    var focus = rows[this.row];
    var html = header('Ajouter une playlist', 'OK : écrire    Retour : annuler') + '<div class="form"><div class="tabs">';
    [['xtream', 'Compte Xtream'], ['remote', 'Lien M3U']].forEach(function (tab) {
      html += '<div class="tab' + (self.mode === tab[0] ? ' selected' : '') + (focus === 'tabs' && self.mode === tab[0] ? ' focus' : '') +
        '">' + tab[1] + '</div>';
    });
    html += '</div>';
    FIELDS[this.mode].forEach(function (field) {
      html += '<label class="field' + (focus === field.key ? ' focus' : '') + '"><span>' + esc(field.label) + '</span>' +
        '<input data-key="' + field.key + '" type="' + (field.type || 'text') + '" value="' + esc(self.values[field.key]) + '"' +
        (field.placeholder ? ' placeholder="' + esc(field.placeholder) + '"' : '') +
        ' autocomplete="off" autocapitalize="off" spellcheck="false"></label>';
    });
    html += '<div class="button' + (focus === 'submit' ? ' focus' : '') + (this.busy ? ' busy' : '') + '">' +
      (this.busy ? 'Vérification…' : 'Ajouter') + '</div>' +
      '<div class="message' + (this.error ? ' error' : '') + '">' + esc(this.message) + '</div></div>';
    appEl.innerHTML = html;
    Array.prototype.forEach.call(appEl.querySelectorAll('input'), function (input) {
      input.addEventListener('input', function () { self.values[input.getAttribute('data-key')] = input.value; });
    });
  };

  AddScreen.prototype.key = function (key) {
    if (this.busy) return key !== KEY.BACK;
    var rows = this.rows();
    var focus = rows[this.row];
    switch (key) {
      case KEY.UP:
      case KEY.DOWN:
        this.row = Math.max(0, Math.min(rows.length - 1, this.row + (key === KEY.UP ? -1 : 1)));
        break;
      case KEY.LEFT:
      case KEY.RIGHT:
        if (focus !== 'tabs') return false;
        this.mode = this.mode === 'xtream' ? 'remote' : 'xtream';
        this.message = '';
        break;
      case KEY.ENTER:
        if (focus === 'submit') return this.submit(), true;
        if (focus === 'tabs') return true;
        var input = appEl.querySelector('input[data-key="' + focus + '"]');
        if (input) input.focus(); // ouvre le clavier du téléviseur
        return true;
      case KEY.BACK:
        show(new HomeScreen());
        return true;
      default:
        return false;
    }
    this.render();
    return true;
  };

  /** Fin de saisie au clavier du téléviseur : on passe au champ suivant. */
  AddScreen.prototype.inputDone = function (validated) {
    if (validated) this.row = Math.min(this.rows().length - 1, this.row + 1);
    this.render();
  };

  AddScreen.prototype.fail = function (message) {
    this.busy = false;
    this.error = true;
    this.message = core.hideLinks(message);
    if (screen === this) this.render();
  };

  AddScreen.prototype.submit = function () {
    var self = this;
    var values = this.values;
    var name = (values.name || '').trim();
    this.error = false;
    if (this.mode === 'xtream') {
      var server = core.xtreamServer(values.server);
      var username = (values.username || '').trim();
      if (!server) return this.fail("Adresse du serveur invalide. Exemple : serveur.com:8080");
      if (!username || !values.password) return this.fail("Il manque l'utilisateur ou le mot de passe.");
      this.busy = true;
      this.message = 'Connexion au serveur…';
      this.render();
      new core.XtreamClient(server, username, values.password, fetchJson).accountInfo().then(function (info) {
        if (screen !== self) return;
        var playlist = store.add({ kind: 'xtream', name: name || hostOf(server), server: server, username: username, password: values.password });
        store.setLastPlaylist(playlist.id);
        show(new BrowseScreen(playlist, info.status.toLowerCase() === 'active' ? null : 'Compte « ' + info.status + ' » chez le fournisseur.'));
      }).catch(function (error) { self.fail(error.message); });
    } else {
      var url = (values.url || '').trim();
      if (!/^https?:\/\/[^/\s]+/i.test(url)) return this.fail('Le lien doit commencer par http:// ou https://');
      this.busy = true;
      this.message = 'Téléchargement de la playlist…';
      this.render();
      loadM3u(url).then(function (channels) {
        if (screen !== self) return;
        var playlist = store.add({ kind: 'remote', name: name || hostOf(url), url: url, channelCount: channels.length });
        store.setLastPlaylist(playlist.id);
        sourceFor(playlist, channels);
        show(new BrowseScreen(playlist));
      }).catch(function (error) { self.fail(error.message); });
    }
  };

  // Navigation dans une playlist : catégories à gauche, chaînes ou films à droite.
  var VISIBLE_ROWS = 9;

  var SEARCH_ENTRY = { name: 'Rechercher', search: true };
  var FAVORITES_ENTRY = { name: 'Favoris', favorites: true };

  /** Ligne d'une chaîne ou d'un film : logo, nom, étoile si favori, action « favori » si demandée. */
  function channelRow(channel, focused, onFavorite) {
    var favorite = store.isFavorite(channel);
    return '<div class="row' + (focused && !onFavorite ? ' focus' : '') + '">' +
      (channel.logoUrl ? '<img class="logo" src="' + esc(channel.logoUrl) + '" onerror="this.style.visibility=\'hidden\'">' : '<span class="logo-space"></span>') +
      '<span class="label">' + esc(channel.name) + '</span>' + (favorite ? ICON.star : '') +
      (focused && onFavorite ? '<span class="action focus">' + (favorite ? 'Retirer des favoris' : 'Ajouter aux favoris') + '</span>' : '') +
      '</div>';
  }

  // Fenêtre d'aperçu de la liste, en coordonnées d'écran 1920 × 1080 (doit suivre .preview-panel .screen).
  var PREVIEW_RECT = { x: 1104, y: 150, width: 720, height: 405 };

  function BrowseScreen(playlist, notice) {
    this.usesPreview = true;
    this.preview = null;
    this.playlist = playlist;
    this.source = sourceFor(playlist);
    this.sectionIndex = 0;
    this.zone = 'categories';
    this.categories = null;
    this.catIndex = 0;
    this.catStatus = '';
    this.channels = null;
    this.chIndex = 0;
    this.chStatus = '';
    this.notice = notice || null;
    this.loadCategories();
  }

  BrowseScreen.prototype.section = function () {
    return this.source.sections ? this.source.sections[this.sectionIndex].id : null;
  };

  BrowseScreen.prototype.loadCategories = function () {
    var self = this;
    var token = this.catToken = {};
    this.categories = null;
    this.channels = null;
    this.catStatus = 'Chargement…';
    this.chStatus = '';
    this.catError = false;
    this.source.categories(this.section()).then(function (list) {
      if (token !== self.catToken) return;
      // « Rechercher » en tête : on y passe en remontant, la première catégorie reste sélectionnée.
      self.categories = list.length ? [SEARCH_ENTRY, FAVORITES_ENTRY].concat(list) : [];
      // On ouvre sur les favoris s'il y en a, sinon sur la première vraie catégorie.
      self.catIndex = list.length ? (self.favoritesHere().length ? 1 : 2) : 0;
      self.catStatus = list.length ? '' : 'Aucune catégorie.';
      if (list.length) self.loadChannels();
      else self.renderIfShown();
    }, function (error) {
      if (token !== self.catToken) return;
      self.catStatus = core.hideLinks(error.message);
      self.catError = true;
      self.renderIfShown();
    });
  };

  BrowseScreen.prototype.loadChannels = function () {
    var self = this;
    var category = this.categories[this.catIndex];
    var token = this.chToken = {};
    this.channels = null;
    this.chIndex = 0;
    if (category === FAVORITES_ENTRY) {
      this.channels = this.favoritesHere();
      this.chStatus = this.channels.length ? '' : 'Aucun favori ici. Appui long sur OK sur une chaîne pour l\'ajouter.';
      this.chError = false;
      this.renderIfShown();
      return;
    }
    if (category === SEARCH_ENTRY) {
      this.chStatus = this.section() === 'movies' ? 'OK : chercher un film par son titre, dans toutes les catégories.'
        : 'OK : chercher une chaîne par son nom, dans toutes les catégories.';
      this.chError = false;
      this.renderIfShown();
      return;
    }
    this.chStatus = 'Chargement…';
    this.chError = false;
    this.renderIfShown();
    this.source.channels(this.section(), category).then(function (list) {
      if (token !== self.chToken) return;
      self.channels = list;
      self.chStatus = list.length ? '' : 'Rien dans cette catégorie.';
      self.renderIfShown();
    }, function (error) {
      if (token !== self.chToken) return;
      self.chStatus = core.hideLinks(error.message);
      self.chError = true;
      self.renderIfShown();
    });
  };

  BrowseScreen.prototype.renderIfShown = function () { if (screen === this) this.render(); };

  BrowseScreen.prototype.afterPlayback = function (index) {
    this.chIndex = index;
    this.zone = 'channels';
    this.onFavorite = false;
    this.preview = null;
    this.schedulePreview();
  };

  /** Favoris de cette playlist (et, pour un compte, de la section affichée : direct ou films). */
  BrowseScreen.prototype.favoritesHere = function () {
    var self = this;
    var section = this.section();
    return store.favorites().filter(function (f) {
      return f.playlistId === self.playlist.id && (!section || !!f.live === (section === 'live'));
    });
  };

  BrowseScreen.prototype.focusedChannel = function () {
    return (this.zone === 'channels' && this.channels && this.channels[this.chIndex]) || null;
  };

  /** Aperçu de la chaîne sélectionnée : lancé après une courte pause, pour ne pas ouvrir chaque chaîne survolée. */
  BrowseScreen.prototype.schedulePreview = function () {
    var self = this;
    var channel = this.focusedChannel();
    if (!channel || (this.preview && this.preview.channel.url === channel.url)) return;
    clearTimeout(this.previewTimer);
    var preview = this.preview = { channel: channel, state: null, guide: null };
    guideFor(channel).then(function (guide) {
      if (self.preview !== preview) return;
      preview.guide = guide;
      self.renderIfShown();
    });
    if (!channel.live) return player.stop();
    if (player.isPlaying(channel)) return;
    player.stop();
    preview.state = 'Chargement…';
    this.previewTimer = setTimeout(function () {
      if (screen === self && self.preview === preview) player.play(channel, PREVIEW_RECT);
    }, 600);
  };

  BrowseScreen.prototype.playerState = function (text) { if (this.preview) { this.preview.state = text; this.renderIfShown(); } };
  BrowseScreen.prototype.playerReady = function () { if (this.preview) { this.preview.state = null; this.renderIfShown(); } };
  BrowseScreen.prototype.playerError = function () {
    if (this.preview) { this.preview.state = 'Aperçu indisponible. OK pour essayer en plein écran.'; this.renderIfShown(); }
  };

  BrowseScreen.prototype.previewHtml = function () {
    var p = this.preview;
    var html = '<div class="preview-panel">';
    if (!p) {
      html += '<div class="screen idle"><span>Sélectionne une chaîne pour la voir ici.</span></div>';
    } else if (p.channel.live) {
      html += '<div class="screen' + (p.state ? ' busy' : '') + '">' + (p.state ? '<span>' + esc(p.state) + '</span>' : '') + '</div>';
    } else {
      html += '<div class="screen poster">' + tile(p.channel, 'poster') + '</div>';
    }
    if (p) {
      html += '<div class="info"><div class="name">' + esc(p.channel.name) + '</div>';
      if (!p.channel.live) {
        var resume = store.resumePosition(p.channel);
        html += '<div class="meta">' + (resume ? 'Reprendre à ' + clock(resume) : 'Film') + '</div>' + progressBar(p.channel);
      } else if (p.guide && p.guide.length) {
        html += guideHtml(p.guide);
      } else {
        html += '<div class="meta">' + esc(p.channel.group || 'Direct') + '</div>';
      }
      html += '</div>';
    }
    return html + '</div>';
  };

  BrowseScreen.prototype.render = function () {
    var self = this;
    var hint = this.zone === 'channels' ? 'OK : plein écran    OK long : favori    Retour : catégories'
      : 'OK ou Droite : ouvrir    Retour : accueil';
    var html = '<div class="layer">' + header(this.playlist.name, hint);
    if (this.source.sections) {
      html += '<div class="sections">';
      this.source.sections.forEach(function (section, i) {
        html += '<div class="tab' + (i === self.sectionIndex ? ' selected' : '') + (self.zone === 'sections' && i === self.sectionIndex ? ' focus' : '') +
          '">' + esc(section.name) + '</div>';
      });
      html += '</div>';
    }
    html += '<div class="browse with-preview"><div class="column categories' + (this.zone === 'categories' ? '' : ' zone-inactive') + '">';
    if (this.notice) html += '<div class="status error">' + esc(this.notice) + '</div>';
    if (this.categories && this.categories.length) {
      var w = windowOf(this.categories.length, this.catIndex, VISIBLE_ROWS);
      for (var i = w.start; i < w.end; i++) {
        var category = this.categories[i];
        var focused = i === this.catIndex;
        html += '<div class="row' + (focused && this.zone !== 'sections' ? ' focus' : '') + (focused ? ' current' : '') + (category.search || category.favorites ? ' search' : '') + '">' +
          (category.search ? ICON.search : category.favorites ? ICON.star : '') + '<span class="label">' + esc(category.name) + '</span>' +
          (category.channels ? '<span class="count">' + category.channels.length + '</span>'
            : category.favorites ? '<span class="count">' + this.favoritesHere().length + '</span>' : '') + '</div>';
      }
    } else {
      html += '<div class="status' + (this.catError ? ' error' : '') + '">' + esc(this.catStatus) + '</div>';
    }
    html += '</div><div class="column channels' + (this.zone === 'channels' ? '' : ' zone-inactive') + '">';
    if (this.channels && this.channels.length) {
      var v = windowOf(this.channels.length, this.chIndex, VISIBLE_ROWS);
      for (var j = v.start; j < v.end; j++) {
        var channel = this.channels[j];
        html += channelRow(channel, j === this.chIndex && this.zone === 'channels', this.onFavorite);
      }
      html += '<div class="position">' + (this.chIndex + 1) + ' / ' + this.channels.length + '</div>';
    } else {
      html += '<div class="status' + (this.chError ? ' error' : '') + '">' + esc(this.chStatus) + '</div>';
    }
    html += '</div></div></div>';
    appEl.innerHTML = html + this.previewHtml();
  };

  BrowseScreen.prototype.moveCategory = function (delta) {
    var self = this;
    var next = Math.max(0, Math.min(this.categories.length - 1, this.catIndex + delta));
    if (next === this.catIndex) return;
    this.catIndex = next;
    // On attend que la sélection se pose avant de charger la catégorie.
    this.chToken = {};
    this.channels = null;
    this.chStatus = 'Chargement…';
    this.chError = false;
    clearTimeout(this.chTimer);
    this.chTimer = setTimeout(function () { self.loadChannels(); }, 350);
  };

  BrowseScreen.prototype.key = function (key) {
    var hasCategories = this.categories && this.categories.length;
    var hasChannels = this.channels && this.channels.length;
    if (this.zone === 'sections') {
      if (key === KEY.LEFT || key === KEY.RIGHT) {
        var count = this.source.sections.length;
        this.sectionIndex = (this.sectionIndex + (key === KEY.LEFT ? count - 1 : 1)) % count;
        player.stop();
        this.preview = null;
        this.loadCategories();
      } else if (key === KEY.DOWN || key === KEY.ENTER) {
        this.zone = 'categories';
      } else if (key === KEY.BACK) {
        return show(new HomeScreen()), true;
      } else {
        return false;
      }
    } else if (this.zone === 'categories') {
      if (key === KEY.UP) {
        if (hasCategories && this.catIndex > 0) this.moveCategory(-1);
        else if (this.source.sections) this.zone = 'sections';
      } else if (key === KEY.DOWN) {
        if (hasCategories) this.moveCategory(1);
      } else if (key === KEY.CHANNEL_UP || key === KEY.CHANNEL_DOWN) {
        if (hasCategories) this.moveCategory(key === KEY.CHANNEL_UP ? -VISIBLE_ROWS : VISIBLE_ROWS);
      } else if (key === KEY.RIGHT || key === KEY.ENTER) {
        if (hasCategories && this.categories[this.catIndex] === SEARCH_ENTRY) return show(new SearchScreen(this)), true;
        if (hasChannels) this.zone = 'channels';
        else if (hasCategories && !this.channels) { clearTimeout(this.chTimer); this.loadChannels(); }
      } else if (key === KEY.BACK) {
        return show(new HomeScreen()), true;
      } else {
        return false;
      }
    } else {
      var handled = listKey(this, this.channels, key);
      if (handled === 'back') this.zone = 'categories';
      else if (!handled) return false;
      else if (handled === 'shown') return true;
    }
    this.schedulePreview();
    this.render();
    return true;
  };

  /**
   * Touches d'une liste de chaînes ou de films (navigation, lecture, favori), partagées par la
   * navigation et la recherche. L'écran porte `chIndex` et `onFavorite`.
   * Renvoie 'shown' si un autre écran s'affiche, 'back' pour Gauche/Retour, true si traité, false sinon.
   */
  function listKey(owner, list, key) {
    if (key === KEY.UP || key === KEY.DOWN) {
      owner.chIndex = Math.max(0, Math.min(list.length - 1, owner.chIndex + (key === KEY.UP ? -1 : 1)));
      owner.onFavorite = false;
    } else if (key === KEY.CHANNEL_UP || key === KEY.CHANNEL_DOWN) {
      owner.chIndex = Math.max(0, Math.min(list.length - 1, owner.chIndex + (key === KEY.CHANNEL_UP ? -VISIBLE_ROWS : VISIBLE_ROWS)));
      owner.onFavorite = false;
    } else if (key === KEY.LONG_ENTER) {
      toggleFavorite(list[owner.chIndex]);
      owner.onFavorite = false;
    } else if (key === KEY.RIGHT) {
      owner.onFavorite = true;
    } else if (key === KEY.ENTER && owner.onFavorite) {
      store.toggleFavorite(list[owner.chIndex]);
      owner.onFavorite = false;
    } else if (key === KEY.ENTER || key === KEY.PLAY || key === KEY.PLAY_PAUSE) {
      owner.onFavorite = false;
      show(new PlayerScreen(owner, list, owner.chIndex));
      return 'shown';
    } else if (key === KEY.LEFT || key === KEY.BACK) {
      if (owner.onFavorite) { owner.onFavorite = false; return true; }
      return 'back';
    } else {
      return false;
    }
    return true;
  }

  // Recherche dans toute une playlist (ou toute une section d'un compte : direct ou films).
  function SearchScreen(browse) {
    var self = this;
    this.browse = browse;
    this.values = { query: '' };
    this.results = [];
    this.chIndex = 0;
    this.zone = 'input';
    this.onFavorite = false;
    this.all = null;
    this.status = 'Chargement de toute la playlist…';
    browse.source.everything(browse.section()).then(function (all) {
      self.all = all;
      self.status = all.length + (browse.section() === 'movies' ? ' films' : ' chaînes') + '. OK pour écrire.';
      self.run();
    }, function (error) {
      self.status = core.hideLinks(error.message);
      self.failed = true;
      if (screen === self) self.render();
    });
  }

  SearchScreen.prototype.run = function () {
    if (this.all) {
      this.results = core.search(this.all, this.values.query);
      this.chIndex = 0;
      if (this.values.query.trim() && !this.results.length) this.status = 'Aucun résultat.';
      else if (this.results.length) this.status = this.results.length + (this.results.length >= 300 ? '+' : '') + ' résultat' + (this.results.length > 1 ? 's' : '');
    }
    if (screen !== this) return;
    if (document.activeElement && document.activeElement.tagName === 'INPUT') this.refresh();
    else this.render();
  };

  SearchScreen.prototype.render = function () {
    var self = this;
    var html = header(this.browse.playlist.name + ' · Rechercher', this.zone === 'input' ? 'OK : écrire    Bas : résultats    Retour : catégories'
      : 'OK : regarder    Droite : favori    Retour : recherche');
    html += '<div class="search"><label class="field' + (this.zone === 'input' ? ' focus' : '') + '">' + ICON.search +
      '<input data-key="query" type="text" value="' + esc(this.values.query) + '" placeholder="' + (this.browse.section() === 'movies' ? 'Titre du film' : 'Nom de la chaîne') + '"' +
      ' autocomplete="off" autocapitalize="off" spellcheck="false"></label>' +
      '<div class="message"></div><div class="column results"></div></div>';
    appEl.innerHTML = html;
    this.refresh();
    var input = appEl.querySelector('input');
    input.addEventListener('input', function () {
      self.values.query = input.value;
      clearTimeout(self.typingTimer);
      self.typingTimer = setTimeout(function () { self.run(); }, 400);
    });
  };

  /** Met à jour l'état et les résultats sans toucher au champ : le clavier du téléviseur reste ouvert. */
  SearchScreen.prototype.refresh = function () {
    var message = appEl.querySelector('.search .message');
    var results = appEl.querySelector('.search .results');
    if (!message || !results) return;
    message.className = 'message' + (this.failed ? ' error' : '');
    message.textContent = this.status;
    var html = '';
    var w = windowOf(this.results.length, this.chIndex, VISIBLE_ROWS - 1);
    for (var i = w.start; i < w.end; i++) html += channelRow(this.results[i], this.zone === 'results' && i === this.chIndex, this.onFavorite);
    results.innerHTML = html;
  };

  SearchScreen.prototype.inputDone = function (validated) {
    clearTimeout(this.typingTimer);
    if (validated && this.results.length) this.zone = 'results';
    this.run();
  };

  SearchScreen.prototype.key = function (key) {
    if (this.zone === 'input') {
      if (key === KEY.ENTER) {
        appEl.querySelector('input').focus(); // ouvre le clavier du téléviseur
        return true;
      }
      if (key === KEY.DOWN && this.results.length) {
        this.zone = 'results';
        this.chIndex = 0;
      } else if (key === KEY.BACK) {
        return show(this.browse), true;
      } else {
        return false;
      }
    } else {
      if (key === KEY.UP && this.chIndex === 0 && !this.onFavorite) {
        this.zone = 'input';
      } else {
        var handled = listKey(this, this.results, key);
        if (handled === 'back') this.zone = 'input';
        else if (!handled) return false;
        else if (handled === 'shown') return true;
      }
    }
    this.render();
    return true;
  };

  SearchScreen.prototype.afterPlayback = function (index) {
    this.chIndex = index;
    this.zone = 'results';
    this.onFavorite = false;
  };

  // Lecture en plein écran, avec un bandeau d'information et, en direct, la liste des chaînes en bas.
  var stripEl = document.getElementById('strip');

  /** Prévient l'écran affiché de ce que fait le lecteur (aperçu de la liste ou plein écran). */
  function route(name, value) { if (screen && screen[name]) screen[name](value); }
  var player = new window.AntennePlayer({
    onState: function (text) { route('playerState', text); },
    onReady: function () { route('playerReady'); },
    onError: function (message) { route('playerError', message); },
    onEnded: function () { route('playerEnded'); },
  });

  function clock(seconds) {
    seconds = Math.max(0, Math.floor(seconds));
    var h = Math.floor(seconds / 3600);
    var m = Math.floor(seconds % 3600 / 60);
    var s = seconds % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  var STRIP_CARDS = 5;

  function PlayerScreen(back, list, index) {
    this.back = back;
    this.list = list;
    this.index = index;
    this.strip = null;
    this.guide = [];
    document.body.classList.add('playing');
    if (player.isPlaying(this.channel())) {
      // Déjà en lecture dans l'aperçu : on agrandit l'image, sans couper.
      player.setRect(null);
      this.error = null;
      this.paused = false;
      this.loadGuide();
      this.playerReady();
    } else {
      this.start();
    }
  }

  PlayerScreen.prototype.channel = function () { return this.list[this.index]; };

  PlayerScreen.prototype.start = function () {
    var self = this;
    this.state = 'Ouverture…';
    this.error = null;
    this.paused = false;
    player.stop();
    clearTimeout(this.zapTimer);
    // Un court délai : zapper plusieurs fois de suite n'ouvre que la dernière chaîne.
    this.zapTimer = setTimeout(function () { if (screen === self) player.play(self.channel()); }, 300);
    this.loadGuide();
    this.showOsd(false);
  };

  PlayerScreen.prototype.loadGuide = function () {
    var self = this;
    var channel = this.channel();
    this.guide = [];
    guideFor(channel).then(function (guide) {
      if (self.channel() !== channel) return;
      self.guide = guide;
      if (screen === self && !osdEl.hidden) self.render();
    });
  };

  PlayerScreen.prototype.playerState = function (text) { this.state = text; this.showOsd(!text); };
  PlayerScreen.prototype.playerReady = function () {
    var self = this;
    var channel = this.channel();
    store.recordWatched(channel);
    this.state = null;
    var resume = channel.live ? null : store.resumePosition(channel);
    if (resume) {
      player.seekTo(resume);
      this.state = 'Reprise à ' + clock(resume);
      setTimeout(function () { if (screen === self && self.state && self.state.indexOf('Reprise') === 0) { self.state = null; self.render(); } }, 4000);
    }
    clearInterval(this.progressTimer);
    if (!channel.live) this.progressTimer = setInterval(function () { self.saveProgress(); }, 10000);
    this.showOsd(true);
  };

  /** Note où en est un film, pour le reprendre plus tard. */
  PlayerScreen.prototype.saveProgress = function () {
    var channel = this.channel();
    if (channel.live || this.error) return;
    var p = player.progress();
    if (p.duration > 0) store.saveProgress(channel, p.position, p.duration);
  };
  PlayerScreen.prototype.playerError = function (message) { this.state = null; this.error = core.hideLinks(message); this.showOsd(false); };
  PlayerScreen.prototype.playerEnded = function () {
    var p = player.progress();
    if (p.duration > 0) store.saveProgress(this.channel(), p.duration, p.duration);
    clearInterval(this.progressTimer);
    this.state = 'Fin de la vidéo.';
    this.showOsd(false);
  };

  PlayerScreen.prototype.render = function () {
    var channel = this.channel();
    var html = '<div class="title">' + esc(channel.name) + (store.isFavorite(channel) ? ' ' + ICON.star : '') + '</div>' +
      '<div class="sub">' + esc(channel.group || '') + ' · ' + (this.index + 1) + ' / ' + this.list.length + '</div>';
    if (this.error) {
      html += '<div class="state error">' + esc(this.error) + '</div><div class="keys">OK : réessayer    Haut/Bas : autre chaîne    Retour : liste</div>';
    } else {
      if (this.state || this.paused) html += '<div class="state">' + esc(this.paused ? 'En pause' : this.state) + '</div>';
      if (!channel.live && !this.state) {
        var p = player.progress();
        if (p.duration > 0) {
          html += '<div class="bar"><i style="width:' + Math.min(100, p.position / p.duration * 100).toFixed(1) + '%"></i></div>' +
            '<div class="sub">' + clock(p.position) + ' / ' + clock(p.duration) + '</div>';
        }
        html += '<div class="keys">OK : pause    Gauche/Droite : −10 s / +30 s    Retour : liste</div>';
      } else {
        html += guideHtml(this.guide);
        html += this.strip === null
          ? '<div class="keys">Bas : liste des chaînes    CH +/− : chaîne précédente / suivante    OK long : favori</div>'
          : '<div class="keys">Gauche/Droite : parcourir    OK : regarder    OK long : favori    Haut : fermer</div>';
      }
    }
    osdEl.innerHTML = html;
  };

  /** Affiche le bandeau ; `autoHide` le retire après quelques secondes. */
  PlayerScreen.prototype.showOsd = function (autoHide) {
    var self = this;
    osdEl.hidden = false;
    this.render();
    clearTimeout(this.osdTimer);
    clearInterval(this.osdTick);
    if (!this.channel().live) this.osdTick = setInterval(function () { if (screen === self && !osdEl.hidden) self.render(); }, 1000);
    if (autoHide && !this.error && !this.paused && this.strip === null) {
      this.osdTimer = setTimeout(function () {
        if (screen !== self) return;
        osdEl.hidden = true;
        clearInterval(self.osdTick);
      }, 5000);
    }
  };

  /** Liste des chaînes en bas de l'écran, à parcourir sans quitter la lecture. */
  PlayerScreen.prototype.openStrip = function () {
    this.strip = this.index;
    this.renderStrip();
    this.showOsd(false);
  };

  PlayerScreen.prototype.renderStrip = function () {
    var self = this;
    var w = windowOf(this.list.length, this.strip, STRIP_CARDS);
    var html = '';
    for (var i = w.start; i < w.end; i++) {
      var channel = this.list[i];
      html += '<div class="card channel' + (i === this.strip ? ' focus' : '') + (i === this.index ? ' current' : '') + '">' +
        tile(channel) + '<div class="name">' + (store.isFavorite(channel) ? ICON.star : '') + esc(channel.name) + '</div></div>';
    }
    stripEl.innerHTML = '<div class="track">' + html + '</div>';
    stripEl.hidden = false;
    osdEl.classList.add('raised');
    clearTimeout(this.stripTimer);
    this.stripTimer = setTimeout(function () { if (screen === self && self.strip !== null) { self.closeStrip(); self.showOsd(true); } }, 12000);
  };

  PlayerScreen.prototype.closeStrip = function () {
    this.strip = null;
    clearTimeout(this.stripTimer);
    stripEl.hidden = true;
    osdEl.classList.remove('raised');
  };

  PlayerScreen.prototype.zap = function (delta) {
    this.goTo((this.index + delta + this.list.length) % this.list.length);
  };

  PlayerScreen.prototype.goTo = function (index) {
    this.saveProgress();
    clearInterval(this.progressTimer);
    this.index = index;
    this.start();
  };

  PlayerScreen.prototype.leave = function () {
    this.saveProgress();
    clearInterval(this.progressTimer);
    this.closeStrip();
    // Retour vers une liste avec aperçu : la chaîne continue dans la petite fenêtre.
    var keep = this.back.usesPreview && this.channel().live && !this.error && player.isPlaying(this.channel());
    if (keep) player.setRect(PREVIEW_RECT);
    else player.stop();
    clearTimeout(this.zapTimer);
    clearTimeout(this.osdTimer);
    clearInterval(this.osdTick);
    osdEl.hidden = true;
    document.body.classList.remove('playing');
    if (this.back.afterPlayback) this.back.afterPlayback(this.index);
    show(this.back);
  };

  PlayerScreen.prototype.key = function (key) {
    var live = this.channel().live;
    if (this.strip !== null) {
      if (key === KEY.LEFT || key === KEY.RIGHT) {
        this.strip = Math.max(0, Math.min(this.list.length - 1, this.strip + (key === KEY.LEFT ? -1 : 1)));
        this.renderStrip();
        return true;
      }
      if (key === KEY.LONG_ENTER) {
        toggleFavorite(this.list[this.strip]);
        this.renderStrip();
        return true;
      }
      if (key === KEY.ENTER) {
        var target = this.strip;
        this.closeStrip();
        if (target !== this.index) this.goTo(target);
        else this.showOsd(true);
        return true;
      }
      if (key === KEY.BACK || key === KEY.UP) {
        this.closeStrip();
        this.showOsd(true);
        return true;
      }
      if (key === KEY.DOWN) return true;
      this.closeStrip();
    }
    // En direct : Bas ouvre la liste des chaînes, Haut montre les infos ; CH +/− zappent.
    if (live && key === KEY.DOWN) {
      this.openStrip();
      return true;
    }
    if (live && key === KEY.UP) {
      this.showOsd(true);
      return true;
    }
    switch (key) {
      case KEY.UP:
      case KEY.CHANNEL_DOWN:
        this.zap(-1);
        return true;
      case KEY.DOWN:
      case KEY.CHANNEL_UP:
        this.zap(1);
        return true;
      case KEY.ENTER:
        if (this.error) this.start();
        else if (live) this.openStrip();
        else if (this.state) this.showOsd(true);
        else this.togglePause();
        return true;
      case KEY.PLAY_PAUSE:
      case KEY.PLAY:
      case KEY.PAUSE:
        if (!live) this.togglePause();
        return true;
      case KEY.LONG_ENTER:
        toggleFavorite(this.channel());
        this.showOsd(true);
        return true;
      case KEY.LEFT:
      case KEY.REWIND:
        if (live) this.openStrip();
        else { player.jump(-10); this.showOsd(true); }
        return true;
      case KEY.RIGHT:
      case KEY.FAST_FORWARD:
        if (live) this.openStrip();
        else { player.jump(30); this.showOsd(true); }
        return true;
      case KEY.BACK:
      case KEY.STOP:
        this.leave();
        return true;
      default:
        return false;
    }
  };

  PlayerScreen.prototype.togglePause = function () {
    var result = player.togglePause();
    if (result) this.paused = result === 'paused';
    this.showOsd(true);
  };

  // ---------- Clavier et cycle de vie ----------

  document.addEventListener('keydown', function (event) {
    var active = document.activeElement;
    if (active && active.tagName === 'INPUT') {
      // Saisie au clavier du téléviseur : on n'intercepte que sa fermeture.
      var key = event.keyCode;
      if (key === KEY.IME_DONE || key === KEY.ENTER || key === KEY.IME_CANCEL || key === KEY.BACK || key === 27) {
        event.preventDefault();
        if (screen && screen.values) screen.values[active.getAttribute('data-key')] = active.value;
        active.blur();
        if (screen && screen.inputDone) screen.inputDone(key === KEY.IME_DONE || key === KEY.ENTER);
      }
      return;
    }
    var code = event.keyCode === 27 || event.keyCode === 8 ? KEY.BACK : event.keyCode; // Échap / effacement hors TV
    if (code === KEY.ENTER && keyupSeen) {
      // OK est traité au relâchement : maintenu plus de 0,7 s, c'est un appui long (favori).
      event.preventDefault();
      if (event.repeat || enterTimer) return;
      enterTimer = setTimeout(function () {
        enterTimer = null;
        if (screen) screen.key(KEY.LONG_ENTER);
      }, 700);
      return;
    }
    if (screen && screen.key(code)) event.preventDefault();
  });

  // Tant qu'on n'a pas vu de relâchement de touche (certains appareils n'en envoient pas),
  // OK agit dès l'appui et l'appui long n'existe pas.
  var keyupSeen = false;
  var enterTimer = null;
  document.addEventListener('keyup', function (event) {
    if (event.keyCode !== KEY.ENTER) return;
    var active = document.activeElement;
    if (active && active.tagName === 'INPUT') return;
    if (!keyupSeen) { keyupSeen = true; return; }
    event.preventDefault();
    if (enterTimer) {
      clearTimeout(enterTimer);
      enterTimer = null;
      if (screen) screen.key(KEY.ENTER);
    }
  });

  document.addEventListener('visibilitychange', function () {
    // L'app passe en arrière-plan (touche Accueil, autre source) : on libère le lecteur.
    if (document.hidden && screen instanceof PlayerScreen) screen.leave();
    if (document.hidden && screen && screen.usesPreview) {
      player.stop();
      screen.preview = null;
    } else if (!document.hidden && screen && screen.schedulePreview) {
      screen.schedulePreview();
      screen.render();
    }
  });

  show(new HomeScreen());
})();
