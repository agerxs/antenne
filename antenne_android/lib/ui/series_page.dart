import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/xtream.dart';
import 'library_scope.dart';
import 'player_page.dart';
import 'widgets.dart';

class SeriesPage extends StatefulWidget {
  const SeriesPage({super.key, required this.series, required this.client});
  final XtreamSeries series;
  final XtreamClient client;

  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  late Future<XtreamSeriesDetail> _detail = widget.client.seriesDetail(widget.series);
  int? _season;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final series = widget.series;
    return Scaffold(
      appBar: AppBar(title: Text(series.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<XtreamSeriesDetail>(
        future: _detail,
        builder: (context, snapshot) {
          final detail = snapshot.data;
          final year = (detail?.releaseDate ?? series.releaseDate);
          final facts = [
            if (year case final y? when y.length >= 4) y.substring(0, 4),
            ?(detail?.genre ?? series.genre),
            if (series.rating case final rating?) '★ $rating',
          ].join(' · ');
          final seasons = detail?.seasons ?? const <XtreamSeason>[];
          final current = seasons.where((s) => s.number == _season).firstOrNull ?? seasons.firstOrNull;

          return ListView(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ChannelLogo(url: detail?.coverUrl ?? series.coverUrl, name: series.name, width: 96, height: 144),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(series.name, style: Theme.of(context).textTheme.titleLarge),
                    if (facts.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 4), child: Text(facts, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
                    if ((detail?.plot ?? series.plot) case final plot?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(plot, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                  ]),
                ),
              ]),
            ),
            if (snapshot.hasError)
              FailureRow(
                message: snapshot.error.toString(),
                onRetry: () => setState(() => _detail = widget.client.seriesDetail(series, forceRefresh: true)),
              )
            else if (detail == null)
              const LoadingRow(text: 'Chargement des épisodes…')
            else if (current == null)
              const ListTile(title: Text('Aucun épisode disponible.'))
            else ...[
              if (seasons.length > 1)
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final season in seasons)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ChoiceChip(
                            label: Text('Saison ${season.number}'),
                            selected: season.number == current.number,
                            onSelected: (_) => setState(() => _season = season.number),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('Saison ${current.number}', style: Theme.of(context).textTheme.labelLarge),
                ),
              for (final episode in current.episodes) _EpisodeTile(episode: episode),
            ],
          ]);
        },
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.episode});
  final XtreamEpisode episode;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final progress = library.progress(episode.channel);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: SizedBox(
        width: 28,
        child: Text(episode.number?.toString() ?? '·',
            textAlign: TextAlign.right, style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      title: Text(episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: episode.duration == null && progress == null
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (episode.duration != null) Text(episode.duration!),
              if (progress != null) Padding(padding: const EdgeInsets.only(top: 6), child: ProgressBadge(progress: progress)),
            ]),
      trailing: library.isFavorite(episode.channel) ? const Icon(Icons.star, size: 18, color: Color(0xFFF7C948)) : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerPage(channel: episode.channel))),
      onLongPress: () => toggleFavorite(context, episode.channel),
    );
  }
}
