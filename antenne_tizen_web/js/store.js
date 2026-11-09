// Données gardées sur le téléviseur (stockage local de l'app, propre à elle) : playlists,
// chaînes regardées, favoris et positions de lecture.
// Le mot de passe d'un compte Xtream y est en clair, comme les liens de lecture qui le contiennent :
// le stockage d'une app Tizen n'est lisible que par elle, mais il n'est pas chiffré comme le trousseau
// d'Android ou d'Apple.
(function (root) {
  'use strict';

  var KEY = 'antenne.v1';
  var HISTORY_SIZE = 20;
  var PROGRESS_SIZE = 200;

  // Mêmes règles que la version Android (PlaybackProgress).
  var FINISHED_FRACTION = 0.95;
  var MINIMUM_RESUME_POSITION = 30;
  var MINIMUM_TRACKED_DURATION = 60;

  function empty() {
    return { playlists: [], lastPlaylistId: null, history: [], favorites: [], progress: {} };
  }

  function read() {
    try {
      var data = JSON.parse(root.localStorage.getItem(KEY) || '{}');
      var state = empty();
      Object.keys(state).forEach(function (key) {
        if (data[key] != null && typeof data[key] === typeof state[key]) state[key] = data[key];
      });
      return state;
    } catch (e) {
      return empty();
    }
  }

  // Le direct Xtream est passé du HLS (.m3u8) au MPEG-TS (.ts) le 2026-11-08 : les chaînes déjà
  // enregistrées (historique, favoris) sont converties, et les deux formes d'un lien comptent pour une.
  var XTREAM_LIVE_HLS = /(\/live\/[^/]+\/[^/]+\/[^/.]+)\.m3u8$/;

  function sameStream(a, b) {
    return a === b || String(a).replace(XTREAM_LIVE_HLS, '$1.ts') === String(b).replace(XTREAM_LIVE_HLS, '$1.ts');
  }

  function upgrade(entry) {
    if (entry.streamId && XTREAM_LIVE_HLS.test(entry.url)) {
      entry.fallbackUrl = entry.url;
      entry.url = entry.url.replace(XTREAM_LIVE_HLS, '$1.ts');
    }
    return entry;
  }

  var state = read();
  state.history.forEach(upgrade);
  state.favorites.forEach(upgrade);

  function save() {
    try {
      root.localStorage.setItem(KEY, JSON.stringify(state));
    } catch (e) {
      // Stockage plein ou indisponible : la session continue, rien n'est gardé.
    }
  }

  /** Ce qu'on garde d'une chaîne : de quoi la relancer et l'afficher. */
  function snapshot(channel) {
    var copy = {};
    ['name', 'url', 'fallbackUrl', 'logoUrl', 'group', 'live', 'streamId', 'userAgent', 'playlistId'].forEach(function (key) {
      if (channel[key] != null) copy[key] = channel[key];
    });
    return copy;
  }

  function withoutUrl(list, url) {
    return list.filter(function (entry) { return !sameStream(entry.url, url); });
  }

  root.AntenneStore = {
    playlists: function () { return state.playlists.slice(); },
    find: function (id) { return state.playlists.filter(function (p) { return p.id === id; })[0] || null; },
    add: function (playlist) {
      playlist.id = 'p' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
      state.playlists.push(playlist);
      save();
      return playlist;
    },
    update: function (id, changes) {
      var playlist = this.find(id);
      if (!playlist) return;
      Object.keys(changes).forEach(function (key) { playlist[key] = changes[key]; });
      save();
    },
    /** Supprime une playlist, et ce qui en venait dans l'historique et les favoris. */
    remove: function (id) {
      var keep = function (entry) { return entry.playlistId !== id; };
      state.playlists = state.playlists.filter(function (p) { return p.id !== id; });
      state.history = state.history.filter(keep);
      state.favorites = state.favorites.filter(keep);
      if (state.lastPlaylistId === id) state.lastPlaylistId = null;
      save();
    },
    lastPlaylistId: function () { return state.lastPlaylistId; },
    setLastPlaylist: function (id) { state.lastPlaylistId = id; save(); },

    /** Chaînes et films lancés, du plus récent au plus ancien. */
    history: function () { return state.history.slice(); },
    recordWatched: function (channel) {
      var entry = snapshot(channel);
      entry.at = Date.now();
      state.history = [entry].concat(withoutUrl(state.history, channel.url)).slice(0, HISTORY_SIZE);
      save();
    },

    favorites: function () { return state.favorites.slice(); },
    isFavorite: function (channel) { return state.favorites.some(function (f) { return sameStream(f.url, channel.url); }); },
    toggleFavorite: function (channel) {
      var was = this.isFavorite(channel);
      state.favorites = was ? withoutUrl(state.favorites, channel.url) : state.favorites.concat([snapshot(channel)]);
      save();
      return !was;
    },

    /** Position à laquelle reprendre un film (secondes), ou null pour repartir du début. */
    resumePosition: function (channel) {
      var entry = state.progress[channel.url];
      if (!entry) return null;
      var finished = entry.duration > 0 && entry.position / entry.duration >= FINISHED_FRACTION;
      return entry.position >= MINIMUM_RESUME_POSITION && !finished ? entry.position : null;
    },
    /** Part déjà vue d'un film, de 0 à 1 (0 si rien n'est noté). */
    watchedFraction: function (channel) {
      var entry = state.progress[channel.url];
      return entry && entry.duration > 0 ? Math.min(1, entry.position / entry.duration) : 0;
    },
    saveProgress: function (channel, position, duration) {
      if (!(duration >= MINIMUM_TRACKED_DURATION) || !(position >= 0)) return;
      state.progress[channel.url] = { position: position, duration: duration, at: Date.now() };
      var urls = Object.keys(state.progress);
      if (urls.length > PROGRESS_SIZE) {
        urls.sort(function (a, b) { return state.progress[a].at - state.progress[b].at; });
        urls.slice(0, urls.length - PROGRESS_SIZE).forEach(function (url) { delete state.progress[url]; });
      }
      save();
    },
  };
})(this);
