import 'package:flutter/material.dart';

import '../core/models.dart';
import 'library_scope.dart';
import 'player_page.dart';

/// « 12:34 » ou « 1:02:03 ».
String timecode(double seconds) {
  final total = seconds.isFinite ? seconds.round().clamp(0, 1 << 31) : 0;
  final h = total ~/ 3600, m = total ~/ 60 % 60, s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// « 21:00 ».
String clock(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

/// Logo d'une chaîne, ou ses initiales quand il manque ou ne charge pas.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.url, required this.name, this.width = 56, this.height = 36});
  final String? url;
  final String name;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = name.split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join().toUpperCase();
    final fallback = Center(
      child: Text(initials, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: width,
        height: height,
        color: scheme.surfaceContainerHigh,
        child: url == null
            ? fallback
            : Padding(
                padding: const EdgeInsets.all(3),
                child: Image.network(url!, fit: BoxFit.contain, errorBuilder: (_, _, _) => fallback),
              ),
      ),
    );
  }
}

/// « Vu », ou la part déjà regardée d'un film ou d'un épisode.
class ProgressBadge extends StatelessWidget {
  const ProgressBadge({super.key, required this.progress});
  final PlaybackProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (progress.isFinished) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text('Vu', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]);
    }
    return SizedBox(
      width: 120,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: progress.fraction, minHeight: 3, backgroundColor: scheme.surfaceContainerHigh),
      ),
    );
  }
}

/// Ligne d'une chaîne, d'un film ou d'un épisode : ouvre le lecteur, appui long pour les favoris.
class ChannelTile extends StatelessWidget {
  const ChannelTile({super.key, required this.channel, this.subtitle});
  final Channel channel;

  /// Remplace le groupe sous le nom (l'émission en cours d'une chaîne en direct, par exemple).
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final progress = library.progress(channel);
    final detail = subtitle ?? channel.group;
    return ListTile(
      leading: ChannelLogo(url: channel.logoUrl, name: channel.name),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: detail == null && progress == null
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (detail != null) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (progress != null) Padding(padding: const EdgeInsets.only(top: 6), child: ProgressBadge(progress: progress)),
            ]),
      trailing: library.isFavorite(channel) ? const Icon(Icons.star, size: 18, color: Color(0xFFF7C948)) : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerPage(channel: channel))),
      onLongPress: () => toggleFavorite(context, channel),
    );
  }
}

Future<void> toggleFavorite(BuildContext context, Channel channel) async {
  final library = LibraryScope.read(context);
  final wasFavorite = library.isFavorite(channel);
  await library.toggleFavorite(channel);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(wasFavorite ? '« ${channel.name} » retiré des favoris' : '« ${channel.name} » ajouté aux favoris'),
      duration: const Duration(seconds: 2),
    ));
}

class LoadingRow extends StatelessWidget {
  const LoadingRow({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class FailureRow extends StatelessWidget {
  const FailureRow({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.error_outline, color: scheme.error),
      title: Text(message, style: TextStyle(color: scheme.error)),
      trailing: TextButton(onPressed: onRetry, child: const Text('Réessayer')),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}
