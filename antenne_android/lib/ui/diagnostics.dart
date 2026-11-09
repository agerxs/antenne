import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import 'device.dart';
import 'player_page.dart';

/// Journal des dernières lectures, gardé sur l'appareil : chaîne, format, moteur, taille d'image ou erreur.
/// Il sert à comprendre une panne à distance, sans aller-retour avec la personne qui regarde.
class PlaybackLog {
  static final entries = <String>[];
  static File? _file;
  static const _max = 60;

  static Future<void> load() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/journal-lecture.txt');
      _file = file;
      if (await file.exists()) entries.addAll((await file.readAsLines()).take(_max));
    } catch (_) {
      // Journal indisponible : l'app fonctionne sans.
    }
  }

  static void add(String message) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    entries.insert(0, '${two(now.day)}/${two(now.month)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $message');
    if (entries.length > _max) entries.removeRange(_max, entries.length);
    _file?.writeAsString(entries.join('\n')).catchError((Object _) => _file!);
  }
}

/// Moteur de lecture choisi à la main (rang dans la liste du lecteur), gardé d'un lancement à l'autre :
/// sur une box où un mode d'affichage reste noir, on ne le choisit qu'une fois.
class EnginePreference {
  static var index = 0;
  static File? _file;

  static Future<void> load() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/moteur.txt');
      _file = file;
      if (await file.exists()) index = int.tryParse((await file.readAsString()).trim()) ?? 0;
    } catch (_) {
      // Préférence indisponible : on part du moteur par défaut.
    }
  }

  static void save(int value) {
    index = value;
    _file?.writeAsString('$value').catchError((Object _) => _file!);
  }
}

/// Le format d'un flux, pour le journal, sans son adresse (celle d'un compte contient le mot de passe).
String streamFormat(Channel channel) {
  final path = Uri.tryParse(channel.url)?.path ?? '';
  final dot = path.lastIndexOf('.');
  final extension = dot >= 0 && path.length - dot <= 6 ? path.substring(dot) : '(sans extension)';
  return '${channel.isLive ? 'direct' : 'vidéo'} $extension';
}

/// Masque les liens d'un message d'erreur.
String hideLinks(Object error) => '$error'.replaceAll(RegExp(r'\w+://\S+'), '[lien]');

/// Vidéos publiques de formats différents : elles disent ce que l'appareil sait décoder et afficher,
/// indépendamment du fournisseur IPTV.
const demoChannels = [
  Channel(name: 'H.264 · HLS (Mux)', group: 'Vidéos de test', url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
  Channel(
      name: 'H.264 · HLS en MPEG-TS (Apple)',
      group: 'Vidéos de test',
      url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8'),
  Channel(
      name: 'H.264 1080p · MP4',
      group: 'Vidéos de test',
      url: 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
  Channel(
      name: 'HEVC (H.265) 1080p · MP4',
      group: 'Vidéos de test',
      url: 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h265/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
  Channel(
      name: 'H.264 1080p · MKV',
      group: 'Vidéos de test',
      url: 'https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_5MB.mkv'),
  Channel(
      name: 'VP9 1080p · WebM',
      group: 'Vidéos de test',
      url: 'https://test-videos.co.uk/vids/bigbuckbunny/webm/vp9/1080/Big_Buck_Bunny_1080_10s_5MB.webm'),
  Channel(
      name: 'AV1 1080p · MP4',
      group: 'Vidéos de test',
      url: 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/av1/1080/Big_Buck_Bunny_1080_10s_5MB.mp4'),
];

const _codecNames = {
  'video/avc': 'H.264',
  'video/hevc': 'HEVC (H.265)',
  'video/mpeg2': 'MPEG-2',
  'video/x-vnd.on2.vp9': 'VP9',
  'video/av01': 'AV1',
  'video/mp4v-es': 'MPEG-4',
  'video/dolby-vision': 'Dolby Vision',
};

/// Décodeurs vidéo par format : « H.264 : matériel (OMX.rk.video_decoder.avc) ».
List<String> _decoderLines(Map<String, Object?> report) {
  final decoders = (report['decoders'] as List?)?.whereType<Map>().toList() ?? const [];
  final lines = <String>[];
  _codecNames.forEach((type, name) {
    final found = decoders.where((d) => d['type'] == type).toList();
    if (found.isEmpty) {
      lines.add('$name : aucun décodeur');
      return;
    }
    final hardware = found.where((d) => d['hardware'] == true).map((d) => d['name']).toList();
    final software = found.where((d) => d['hardware'] != true).map((d) => d['name']).toList();
    lines.add('$name : ${hardware.isNotEmpty ? 'matériel (${hardware.join(', ')})' : 'logiciel seulement (${software.join(', ')})'}');
  });
  return lines;
}

List<String> _deviceLines(Map<String, Object?> report) => [
      'Antenne ${appVersion ?? '?'}',
      'Appareil : ${report['manufacturer']} ${report['model']}',
      'Android ${report['android']} (API ${report['sdk']})',
      'Puce : ${report['soc'] ?? report['hardware']}',
      'OpenGL ES ${report['gles']}',
      'Écran : ${report['screen']}',
      'Téléviseur : ${isTelevision ? 'oui' : 'non'}',
      'Lecteur essayé en premier : ${const ['ExoPlayer · texture', 'ExoPlayer · surface', 'mpv'][EnginePreference.index % 3]}',
    ];

String _reportText(Map<String, Object?> report) => [
      'Diagnostic Antenne',
      ..._deviceLines(report),
      '',
      'Décodeurs vidéo',
      ..._decoderLines(report),
      '',
      'Dernières lectures',
      ...PlaybackLog.entries.take(25),
    ].join('\n');

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  late final Future<Map<String, Object?>> _report = deviceReport();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    Widget title(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary)),
        );
    Widget line(String text) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2), child: Text(text, style: muted));

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic')),
      body: FutureBuilder<Map<String, Object?>>(
        future: _report,
        builder: (context, snapshot) {
          final report = snapshot.data ?? const <String, Object?>{};
          return ListView(padding: const EdgeInsets.only(bottom: 48), children: [
            ListTile(
              leading: const Icon(Icons.send_outlined),
              title: const Text('Envoyer le diagnostic'),
              subtitle: const Text('Par WhatsApp, e-mail… Sinon, prends cette page en photo.'),
              onTap: () => shareText(_reportText(report)),
            ),
            title('Vidéos de test'),
            line("Lance-les une par une : chacune dit si l'appareil sait lire ce format."),
            for (final channel in demoChannels)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(channel.name),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerPage(channel: channel)));
                  if (mounted) setState(() {});
                },
              ),
            title('Appareil'),
            for (final text in _deviceLines(report)) line(text),
            title('Décodeurs vidéo'),
            if (snapshot.hasData) for (final text in _decoderLines(report)) line(text) else line('Lecture en cours…'),
            title('Dernières lectures'),
            if (PlaybackLog.entries.isEmpty) line('Aucune lecture pour le moment.'),
            for (final text in PlaybackLog.entries.take(25)) line(text),
          ]);
        },
      ),
    );
  }
}
