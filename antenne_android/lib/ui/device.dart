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
