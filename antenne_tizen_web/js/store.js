// Playlists enregistrées sur le téléviseur (stockage local de l'app, propre à elle).
// Le mot de passe d'un compte Xtream y est en clair : le stockage d'une app Tizen n'est lisible
// que par elle, mais il n'est pas chiffré comme le trousseau d'Android ou d'Apple.
(function (root) {
  'use strict';

  var KEY = 'antenne.v1';

  function read() {
    try {
      var data = JSON.parse(root.localStorage.getItem(KEY) || '{}');
      return { playlists: Array.isArray(data.playlists) ? data.playlists : [], lastPlaylistId: data.lastPlaylistId || null };
    } catch (e) {
      return { playlists: [], lastPlaylistId: null };
    }
  }

  var state = read();

  function save() {
    try {
      root.localStorage.setItem(KEY, JSON.stringify(state));
    } catch (e) {
      // Stockage plein ou indisponible : la session continue, rien n'est gardé.
    }
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
    remove: function (id) {
      state.playlists = state.playlists.filter(function (p) { return p.id !== id; });
      if (state.lastPlaylistId === id) state.lastPlaylistId = null;
      save();
    },
    lastPlaylistId: function () { return state.lastPlaylistId; },
    setLastPlaylist: function (id) { state.lastPlaylistId = id; save(); },
  };
})(this);
