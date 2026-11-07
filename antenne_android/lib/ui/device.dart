import 'package:flutter/services.dart';

/// Vrai sur un téléviseur ou un boîtier Android TV : lecture en plein écran, pilotage à la télécommande.
/// `--dart-define=ANTENNE_TV=true` force ce mode, pour l'essayer sur un téléphone ou un émulateur.
bool isTelevision = const bool.fromEnvironment('ANTENNE_TV');

Future<void> detectTelevision() async {
  if (isTelevision) return;
  try {
    isTelevision = await const MethodChannel('antenne/device').invokeMethod<bool>('isTelevision') ?? false;
  } on PlatformException {
    isTelevision = false;
  }
}
