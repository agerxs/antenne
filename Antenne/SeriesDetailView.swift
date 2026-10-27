import AntenneCore
import SwiftUI

struct SeriesDetailView: View {
    @Environment(PlaylistStore.self) private var store
    let series: XtreamSeries
    let client: XtreamClient

    @State private var detail: LoadState<XtreamSeriesDetail> = .idle
    @State private var seasonNumber: Int?

    var body: some View {
        List {
            Section { header }

            switch detail {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Chargement des épisodes…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Réessayer") { Task { await load(force: true) } }.buttonStyle(.borderless)
                }
            case .loaded(let detail):
                if detail.seasons.isEmpty {
                    Text("Aucun épisode disponible.").foregroundStyle(.secondary)
                } else {
                    episodes(of: detail)
                }
            }
        }
        .navigationTitle(series.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: Channel.self) { PlayerView(channel: $0) }
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ChannelLogo(url: loadedDetail?.coverURL ?? series.coverURL, name: series.name)
                .frame(width: 96, height: 144)
            VStack(alignment: .leading, spacing: 6) {
                Text(series.name)
                    .font(.title3.weight(.semibold))
                if let facts {
                    Text(facts).font(.caption).foregroundStyle(.secondary)
                }
                if let plot = loadedDetail?.plot ?? series.plot {
                    Text(plot)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func episodes(of detail: XtreamSeriesDetail) -> some View {
        let current = detail.seasons.first { $0.number == seasonNumber } ?? detail.seasons[0]
        Section {
            ForEach(current.episodes) { episode in
                NavigationLink(value: episode.channel) {
                    EpisodeRow(episode: episode, isFavorite: store.isFavorite(episode.channel),
                               progress: store.progress(for: episode.channel))
                }
                .contextMenu { FavoriteButton(channel: episode.channel) }
            }
        } header: {
            if detail.seasons.count > 1 {
                Picker("Saison", selection: Binding(get: { current.number }, set: { seasonNumber = $0 })) {
                    ForEach(detail.seasons) { Text("Saison \($0.number)").tag($0.number) }
                }
                .pickerStyle(.menu)
                .textCase(nil)
            } else {
                Text("Saison \(current.number)")
            }
        }
    }

    private var loadedDetail: XtreamSeriesDetail? {
        if case .loaded(let detail) = detail { return detail }
        return nil
    }

    private var facts: String? {
        let year = (loadedDetail?.releaseDate ?? series.releaseDate).map { String($0.prefix(4)) }
        let parts = [year, loadedDetail?.genre ?? series.genre, series.rating.map { "★ \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load(force: Bool) async {
        if case .loaded = detail, !force { return }
        if loadedDetail == nil { detail = .loading }
        do {
            let client = client
            let series = series
            detail = .loaded(try await uncancellable { try await client.seriesDetail(series, forceRefresh: force) })
        } catch {
            detail = .failed(error.localizedDescription)
        }
    }
}

private struct EpisodeRow: View {
    let episode: XtreamEpisode
    let isFavorite: Bool
    let progress: PlaybackProgress?

    var body: some View {
        HStack(spacing: 12) {
            Text(episode.number.map { "\($0)" } ?? "·")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(2)
                if let duration = episode.duration {
                    Text(duration).font(.caption).foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressBadge(progress: progress)
                }
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favori")
            }
        }
    }
}
