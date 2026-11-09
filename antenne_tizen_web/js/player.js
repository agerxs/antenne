// Lecteur Samsung AVPlay, piloté directement : c'est lui que les apps IPTV utilisent sur ces TV.
// (Le plugin Flutter qui l'enveloppe reste bloqué sur le MP4 et le HLS : voir la mémoire du projet.)
(function (root) {
  'use strict';

  var PREPARE_TIMEOUT = 25000;
  var FULL_SCREEN = { x: 0, y: 0, width: 1920, height: 1080 };

  // Beaucoup d'abonnements n'autorisent qu'une connexion à la fois, et le fournisseur met
  // quelques secondes à libérer celle de la chaîne qu'on vient de quitter : il refuse alors la
  // suivante (PLAYER_ERROR_CONNECTION_FAILED). On réessaie, en espaçant les tentatives.
  var RETRY_DELAYS = [1500, 3000, 5000];
  var CONNECTION_REFUSED = /CONNECTION|NETWORK/i;

  function avplay() { return root.webapis && root.webapis.avplay; }

  function Player(callbacks) {
    this.callbacks = callbacks; // onState(texte), onReady(), onError(message), onEnded()
    this.session = 0;
  }

  Player.prototype.available = function () { return !!avplay(); };

  /**
   * Lance `channel`, en plein écran ou dans `rect` (coordonnées d'un écran de 1920 × 1080),
   * par exemple la fenêtre d'aperçu de la liste des chaînes.
   */
  Player.prototype.play = function (channel, rect, attempt) {
    var player = avplay();
    var self = this;
    var session = ++this.session;
    attempt = attempt || 0;
    this.stop(true);
    this.rect = rect || FULL_SCREEN;
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
      player.setDisplayRect(this.rect.x, this.rect.y, this.rect.width, this.rect.height);
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
          if (!self.retry(channel, rect, attempt, session, String(error))) self.callbacks.onError('Erreur du lecteur : ' + error);
        },
      });
      player.prepareAsync(function () {
        if (session !== self.session) return;
        clearTimeout(timer);
        player.play();
        self.playingUrl = channel.originalUrl || channel.url;
        self.callbacks.onReady();
      }, function (error) {
        if (session !== self.session) return;
        clearTimeout(timer);
        self.stop(true);
        var text = describe(error);
        if (self.retry(channel, rect, attempt, session, text)) return;
        if (channel.fallbackUrl && channel.fallbackUrl !== channel.url && !CONNECTION_REFUSED.test(text)) {
          // Ce fournisseur ne sert pas le direct en MPEG-TS : on essaie le HLS.
          var hls = {};
          Object.keys(channel).forEach(function (key) { hls[key] = channel[key]; });
          hls.url = channel.fallbackUrl;
          hls.originalUrl = channel.url;
          hls.fallbackUrl = null;
          self.play(hls, rect);
          return;
        }
        self.callbacks.onError(CONNECTION_REFUSED.test(text)
          ? 'Le fournisseur refuse la connexion (' + text + '). Si ton abonnement n\'autorise qu\'un écran, ' +
            'vérifie qu\'aucun autre appareil ne regarde en ce moment.'
          : 'Le lecteur ne sait pas lire ce flux (' + text + ').');
      });
    } catch (e) {
      clearTimeout(timer);
      this.stop(true);
      this.callbacks.onError('Le lecteur a refusé ce flux (' + describe(e) + ').');
    }
  };

  /** Relance après un refus de connexion ; faux si on a épuisé les tentatives ou si l'erreur est d'une autre nature. */
  Player.prototype.retry = function (channel, rect, attempt, session, errorText) {
    var self = this;
    if (attempt >= RETRY_DELAYS.length || !CONNECTION_REFUSED.test(errorText)) return false;
    this.callbacks.onState('Connexion refusée, nouvel essai (' + (attempt + 1) + '/' + RETRY_DELAYS.length + ')…');
    setTimeout(function () {
      if (session === self.session) self.play(channel, rect, attempt + 1);
    }, RETRY_DELAYS[attempt]);
    return true;
  };

  /** Arrête la lecture. `keepSession` : ne pas invalider les rappels de la lecture en cours de lancement. */
  Player.prototype.stop = function (keepSession) {
    if (!keepSession) this.session++;
    this.playingUrl = null;
    var player = avplay();
    if (!player) return;
    try { player.stop(); } catch (e) { /* déjà arrêté */ }
    try { player.close(); } catch (e) { /* déjà fermé */ }
  };

  /** Déplace l'image (aperçu ↔ plein écran) sans couper la lecture. */
  Player.prototype.setRect = function (rect) {
    this.rect = rect || FULL_SCREEN;
    try { avplay().setDisplayRect(this.rect.x, this.rect.y, this.rect.width, this.rect.height); } catch (e) { /* pas de lecture */ }
  };

  /** Vrai si `channel` est déjà en cours de lecture (lancée et prête). */
  Player.prototype.isPlaying = function (channel) {
    return !!channel && this.playingUrl === channel.url;
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

  /** Place la lecture à `seconds` (reprise d'un film). */
  Player.prototype.seekTo = function (seconds) {
    var player = avplay();
    if (!player || this.live) return;
    try { player.seekTo(Math.floor(seconds * 1000)); } catch (e) { /* contenu sans recherche */ }
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
