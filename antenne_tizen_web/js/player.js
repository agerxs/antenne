// Lecteur Samsung AVPlay, piloté directement : c'est lui que les apps IPTV utilisent sur ces TV.
// (Le plugin Flutter qui l'enveloppe reste bloqué sur le MP4 et le HLS : voir la mémoire du projet.)
(function (root) {
  'use strict';

  var PREPARE_TIMEOUT = 25000;

  function avplay() { return root.webapis && root.webapis.avplay; }

  function Player(callbacks) {
    this.callbacks = callbacks; // onState(texte), onReady(), onError(message), onEnded()
    this.session = 0;
  }

  Player.prototype.available = function () { return !!avplay(); };

  Player.prototype.play = function (channel) {
    var player = avplay();
    var self = this;
    var session = ++this.session;
    this.stop(true);
    if (!player) {
      this.callbacks.onError("Le lecteur du téléviseur n'est pas disponible.");
      return;
    }
    this.live = channel.live !== false;
    var timer = setTimeout(function () {
      if (session !== self.session) return;
      self.stop(true);
      self.callbacks.onError('Le flux ne répond pas (aucune image après 25 secondes).');
    }, PREPARE_TIMEOUT);

    try {
      player.open(channel.url);
      player.setDisplayRect(0, 0, 1920, 1080);
      try { player.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX'); } catch (e) { /* mode par défaut */ }
      if (channel.userAgent) {
        try { player.setStreamingProperty('USER_AGENT', channel.userAgent); } catch (e) { /* non pris en charge */ }
      }
      player.setListener({
        onbufferingstart: function () { if (session === self.session) self.callbacks.onState('Chargement…'); },
        onbufferingcomplete: function () { if (session === self.session) self.callbacks.onState(null); },
        onstreamcompleted: function () { if (session === self.session) self.callbacks.onEnded(); },
        onerror: function (error) {
          if (session !== self.session) return;
          clearTimeout(timer);
          self.stop(true);
          self.callbacks.onError('Erreur du lecteur : ' + error);
        },
      });
      player.prepareAsync(function () {
        if (session !== self.session) return;
        clearTimeout(timer);
        player.play();
        self.callbacks.onReady();
      }, function (error) {
        if (session !== self.session) return;
        clearTimeout(timer);
        self.stop(true);
        self.callbacks.onError('Le lecteur ne sait pas lire ce flux (' + describe(error) + ').');
      });
    } catch (e) {
      clearTimeout(timer);
      this.stop(true);
      this.callbacks.onError('Le lecteur a refusé ce flux (' + describe(e) + ').');
    }
  };

  /** Arrête la lecture. `keepSession` : ne pas invalider les rappels de la lecture en cours de lancement. */
  Player.prototype.stop = function (keepSession) {
    if (!keepSession) this.session++;
    var player = avplay();
    if (!player) return;
    try { player.stop(); } catch (e) { /* déjà arrêté */ }
    try { player.close(); } catch (e) { /* déjà fermé */ }
  };

  Player.prototype.state = function () {
    try { return avplay().getState(); } catch (e) { return 'NONE'; }
  };

  Player.prototype.togglePause = function () {
    var player = avplay();
    if (!player) return null;
    try {
      if (player.getState() === 'PLAYING') { player.pause(); return 'paused'; }
      if (player.getState() === 'PAUSED') { player.play(); return 'playing'; }
    } catch (e) { /* état transitoire */ }
    return null;
  };

  /** Avance (secondes positives) ou recule ; sans effet sur le direct. */
  Player.prototype.jump = function (seconds) {
    var player = avplay();
    if (!player || this.live) return;
    try {
      if (seconds > 0) player.jumpForward(seconds * 1000);
      else player.jumpBackward(-seconds * 1000);
    } catch (e) { /* hors limites */ }
  };

  /** Position et durée en secondes (durée 0 pour le direct). */
  Player.prototype.progress = function () {
    var player = avplay();
    try {
      return { position: player.getCurrentTime() / 1000, duration: this.live ? 0 : player.getDuration() / 1000 };
    } catch (e) {
      return { position: 0, duration: 0 };
    }
  };

  function describe(error) {
    if (!error) return 'erreur inconnue';
    if (typeof error === 'string') return error;
    return [error.name, error.message].filter(Boolean).join(' : ') || String(error);
  }

  root.AntennePlayer = Player;
})(this);
