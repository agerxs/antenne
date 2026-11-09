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
  };

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
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
      source = {
        sections: [{ id: 'live', name: 'Direct' }, { id: 'movies', name: 'Films' }],
        categories: function (section) { return client.categories(section); },
        channels: function (section, category) {
          return client.channels(section, category).then(function (list) {
            list.forEach(function (channel) { channel.live = section === 'live'; });
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
              channels.forEach(function (channel) { channel.live = !VOD.test(channel.url); });
              return core.groupChannels(channels);
            });
            groups.catch(function () { groups = null; });
          }
          return groups;
        },
        channels: function (section, category) { return Promise.resolve(category.channels); },
      };
    }
    sources[playlist.id] = source;
    return source;
  }

  // ---------- Écrans ----------

  var screen = null;
  function show(next) {
    screen = next;
    screen.render();
  }

  function exitApp() {
    try { window.tizen.application.getCurrentApplication().exit(); } catch (e) { /* navigateur de test */ }
  }

  // Accueil : les playlists, et l'ajout d'une nouvelle.
  function HomeScreen() {
    var playlists = store.playlists();
    var last = store.lastPlaylistId();
    this.index = Math.max(0, playlists.map(function (p) { return p.id; }).indexOf(last));
    this.onDelete = false;
    this.confirm = false;
  }

  HomeScreen.prototype.render = function () {
    var self = this;
    var playlists = store.playlists();
    this.index = Math.min(this.index, playlists.length);
    var html = header(null, 'OK : ouvrir    Droite : supprimer    Retour : quitter');
    if (!playlists.length) {
      html += '<p class="empty">Ajoute une playlist pour commencer : un compte Xtream (serveur, utilisateur et mot de passe ' +
        'donnés par ton fournisseur) ou un lien M3U.</p>';
    }
    html += '<div class="home-list">';
    playlists.forEach(function (playlist, i) {
      var focused = i === self.index;
      var meta = playlist.kind === 'xtream' ? 'Compte · ' + hostOf(playlist.server)
        : 'Lien M3U' + (playlist.channelCount ? ' · ' + playlist.channelCount + ' chaînes' : '');
      html += '<div class="row' + (focused && !self.onDelete ? ' focus' : '') + '">' +
        (playlist.kind === 'xtream' ? ICON.account : ICON.list) +
        '<span class="label">' + esc(playlist.name) + '</span><span class="meta">' + esc(meta) + '</span>' +
        '<span class="action' + (focused && self.onDelete ? ' focus' : '') + '">' +
        (focused && self.confirm ? 'Confirmer la suppression' : 'Supprimer') + '</span></div>';
    });
    html += '<div class="row' + (this.index === playlists.length ? ' focus' : '') + '">' + ICON.plus +
      '<span class="label">Ajouter une playlist</span></div></div>';
    appEl.innerHTML = html;
  };

  HomeScreen.prototype.key = function (key) {
    var playlists = store.playlists();
    var onPlaylist = this.index < playlists.length;
    switch (key) {
      case KEY.UP:
      case KEY.DOWN:
        this.index = Math.max(0, Math.min(playlists.length, this.index + (key === KEY.UP ? -1 : 1)));
        this.onDelete = this.confirm = false;
        break;
      case KEY.RIGHT:
        if (onPlaylist) this.onDelete = true;
        break;
      case KEY.LEFT:
        this.onDelete = this.confirm = false;
        break;
      case KEY.ENTER:
        if (!onPlaylist) return show(new AddScreen()), true;
        if (!this.onDelete) {
          store.setLastPlaylist(playlists[this.index].id);
          return show(new BrowseScreen(playlists[this.index])), true;
        }
        if (!this.confirm) {
          this.confirm = true;
        } else {
          delete sources[playlists[this.index].id];
          store.remove(playlists[this.index].id);
          this.onDelete = this.confirm = false;
        }
        break;
      case KEY.BACK:
        exitApp();
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

  function BrowseScreen(playlist, notice) {
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
      self.categories = list;
      self.catIndex = 0;
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

  BrowseScreen.prototype.render = function () {
    var self = this;
    var hint = this.zone === 'channels' ? 'OK : regarder    CH +/− : page    Retour : catégories' : 'OK ou Droite : ouvrir    Retour : accueil';
    var html = header(this.playlist.name, hint);
    if (this.source.sections) {
      html += '<div class="sections">';
      this.source.sections.forEach(function (section, i) {
        html += '<div class="tab' + (i === self.sectionIndex ? ' selected' : '') + (self.zone === 'sections' && i === self.sectionIndex ? ' focus' : '') +
          '">' + esc(section.name) + '</div>';
      });
      html += '</div>';
    }
    html += '<div class="browse"><div class="column categories' + (this.zone === 'categories' ? '' : ' zone-inactive') + '">';
    if (this.notice) html += '<div class="status error">' + esc(this.notice) + '</div>';
    if (this.categories && this.categories.length) {
      var w = windowOf(this.categories.length, this.catIndex, VISIBLE_ROWS);
      for (var i = w.start; i < w.end; i++) {
        var category = this.categories[i];
        var focused = i === this.catIndex;
        html += '<div class="row' + (focused && this.zone !== 'sections' ? ' focus' : '') + (focused ? ' current' : '') + '"><span class="label">' +
          esc(category.name) + '</span>' + (category.channels ? '<span class="count">' + category.channels.length + '</span>' : '') + '</div>';
      }
    } else {
      html += '<div class="status' + (this.catError ? ' error' : '') + '">' + esc(this.catStatus) + '</div>';
    }
    html += '</div><div class="column channels' + (this.zone === 'channels' ? '' : ' zone-inactive') + '">';
    if (this.channels && this.channels.length) {
      var v = windowOf(this.channels.length, this.chIndex, VISIBLE_ROWS);
      for (var j = v.start; j < v.end; j++) {
        var channel = this.channels[j];
        html += '<div class="row' + (j === this.chIndex && this.zone === 'channels' ? ' focus' : '') + '">' +
          (channel.logoUrl ? '<img class="logo" src="' + esc(channel.logoUrl) + '" onerror="this.style.visibility=\'hidden\'">' : '<span class="logo-space"></span>') +
          '<span class="label">' + esc(channel.name) + '</span></div>';
      }
      html += '<div class="position">' + (this.chIndex + 1) + ' / ' + this.channels.length + '</div>';
    } else {
      html += '<div class="status' + (this.chError ? ' error' : '') + '">' + esc(this.chStatus) + '</div>';
    }
    html += '</div></div>';
    appEl.innerHTML = html;
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
        if (hasChannels) this.zone = 'channels';
        else if (hasCategories && !this.channels) { clearTimeout(this.chTimer); this.loadChannels(); }
      } else if (key === KEY.BACK) {
        return show(new HomeScreen()), true;
      } else {
        return false;
      }
    } else {
      if (key === KEY.UP || key === KEY.DOWN) {
        this.chIndex = Math.max(0, Math.min(this.channels.length - 1, this.chIndex + (key === KEY.UP ? -1 : 1)));
      } else if (key === KEY.CHANNEL_UP || key === KEY.CHANNEL_DOWN) {
        this.chIndex = Math.max(0, Math.min(this.channels.length - 1, this.chIndex + (key === KEY.CHANNEL_UP ? -VISIBLE_ROWS : VISIBLE_ROWS)));
      } else if (key === KEY.ENTER || key === KEY.PLAY || key === KEY.PLAY_PAUSE) {
        return show(new PlayerScreen(this, this.channels, this.chIndex)), true;
      } else if (key === KEY.LEFT || key === KEY.BACK) {
        this.zone = 'categories';
      } else {
        return false;
      }
    }
    this.render();
    return true;
  };

  // Lecture en plein écran, avec un bandeau d'information.
  var player = new window.AntennePlayer({
    onState: function (text) { if (screen instanceof PlayerScreen) screen.setState(text); },
    onReady: function () { if (screen instanceof PlayerScreen) screen.ready(); },
    onError: function (message) { if (screen instanceof PlayerScreen) screen.fail(message); },
    onEnded: function () { if (screen instanceof PlayerScreen) screen.ended(); },
  });

  function clock(seconds) {
    seconds = Math.max(0, Math.floor(seconds));
    var h = Math.floor(seconds / 3600);
    var m = Math.floor(seconds % 3600 / 60);
    var s = seconds % 60;
    return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  function PlayerScreen(back, list, index) {
    this.back = back;
    this.list = list;
    this.index = index;
    document.body.classList.add('playing');
    this.start();
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
    this.showOsd(false);
  };

  PlayerScreen.prototype.setState = function (text) { this.state = text; this.showOsd(!text); };
  PlayerScreen.prototype.ready = function () { this.state = null; this.showOsd(true); };
  PlayerScreen.prototype.fail = function (message) { this.state = null; this.error = core.hideLinks(message); this.showOsd(false); };
  PlayerScreen.prototype.ended = function () { this.state = 'Fin de la vidéo.'; this.showOsd(false); };

  PlayerScreen.prototype.render = function () {
    var channel = this.channel();
    var html = '<div class="title">' + esc(channel.name) + '</div>' +
      '<div class="sub">' + esc(channel.group || this.back.playlist.name) + ' · ' + (this.index + 1) + ' / ' + this.list.length + '</div>';
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
        html += '<div class="keys">Haut/Bas ou CH +/− : chaîne précédente / suivante    OK : infos    Retour : liste</div>';
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
    if (autoHide && !this.error && !this.paused) {
      this.osdTimer = setTimeout(function () {
        if (screen !== self) return;
        osdEl.hidden = true;
        clearInterval(self.osdTick);
      }, 5000);
    }
  };

  PlayerScreen.prototype.zap = function (delta) {
    this.index = (this.index + delta + this.list.length) % this.list.length;
    this.start();
  };

  PlayerScreen.prototype.leave = function () {
    player.stop();
    clearTimeout(this.zapTimer);
    clearTimeout(this.osdTimer);
    clearInterval(this.osdTick);
    osdEl.hidden = true;
    document.body.classList.remove('playing');
    this.back.chIndex = this.index;
    this.back.zone = 'channels';
    show(this.back);
  };

  PlayerScreen.prototype.key = function (key) {
    var live = this.channel().live;
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
        else if (live || this.state) this.showOsd(true);
        else this.togglePause();
        return true;
      case KEY.PLAY_PAUSE:
      case KEY.PLAY:
      case KEY.PAUSE:
        if (!live) this.togglePause();
        return true;
      case KEY.LEFT:
      case KEY.REWIND:
        if (!live) { player.jump(-10); this.showOsd(true); }
        return true;
      case KEY.RIGHT:
      case KEY.FAST_FORWARD:
        if (!live) { player.jump(30); this.showOsd(true); }
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
    if (screen && screen.key(code)) event.preventDefault();
  });

  document.addEventListener('visibilitychange', function () {
    // L'app passe en arrière-plan (touche Accueil, autre source) : on libère le lecteur.
    if (document.hidden && screen instanceof PlayerScreen) screen.leave();
  });

  var last = store.find(store.lastPlaylistId());
  show(last ? new BrowseScreen(last) : new HomeScreen());
})();
