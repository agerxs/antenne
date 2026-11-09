import 'package:flutter/services.dart';

const _channel = MethodChannel('antenne/device');

/// Vrai sur un téléviseur ou un boîtier Android TV : lecture en plein écran, pilotage à la télécommande.
/// `--dart-define=ANTENNE_TV=true` force ce mode, pour l'essayer sur un téléphone ou un émulateur.
bool isTelevision = const bool.fromEnvironment('ANTENNE_TV');

Future<void> detectTelevision() async {
  if (isTelevision) return;
  try {
    isTelevision = await _channel.invokeMethod<bool>('isTelevision') ?? false;
  } on PlatformException {
    isTelevision = false;
  }
}

/// Version installée, par exemple « 1.0.0 (8) », ou null si on ne peut pas la lire.
String? appVersion;

Future<void> detectAppVersion() async {
  try {
    appVersion = await _channel.invokeMethod<String>('appVersion');
  } on MissingPluginException {
    appVersion = null;
  } on PlatformException {
    appVersion = null;
  }
}

/// Appareil, puce, OpenGL ES et décodeurs vidéo (voir MainActivity.deviceReport).
Future<Map<String, Object?>> deviceReport() async {
  try {
    return await _channel.invokeMapMethod<String, Object?>('deviceReport') ?? const {};
  } on MissingPluginException {
    return const {};
  } on PlatformException {
    return const {};
  }
}

/// Ouvre le partage d'Android avec ce texte. Faux si l'appareil n'a aucune app pour le recevoir.
Future<bool> shareText(String text) async {
  try {
    return await _channel.invokeMethod<bool>('shareText', text) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Empêche l'écran de s'éteindre ou l'économiseur de démarrer tant que [on] est vrai.
Future<void> keepScreenOn(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepScreenOn', on);
  } on MissingPluginException {
    // Tests et plateformes sans le canal natif : rien à faire.
  } on PlatformException {
    // L'écran s'éteindra selon les réglages système : ce n'est pas bloquant.
  }
}
