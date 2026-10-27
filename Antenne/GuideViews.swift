import AntenneCore
import SwiftUI

/// Guide des programmes sous la vidéo d'une chaîne en direct.
struct GuidePanel: View {
    let channel: Channel
    let client: XtreamClient
    @State private var programmes: LoadState<[EPGProgramme]> = .idle

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section("Programme") {
                    switch programmes {
                    case .idle, .loading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Chargement du guide…").foregroundStyle(.secondary)
                        }
                    case .failed:
                        Text("Guide indisponible pour le moment.").foregroundStyle(.secondary)
                    case .loaded(let all):
                        let upcoming = all.filter { $0.end > context.date }
                        if upcoming.isEmpty {
                            Text("Aucun programme annoncé pour cette chaîne.").foregroundStyle(.secondary)
                        }
                        ForEach(upcoming) { programme in
                            ProgrammeRow(programme: programme, now: context.date)
                        }
                    }
                }
            }
        }
        .task(id: channel.id) {
            // Le guide se met à jour tant que la chaîne reste affichée.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10 * 60))
            }
        }
    }

    private func load() async {
        if case .loaded = programmes {} else { programmes = .loading }
        let client = client
        let channel = channel
        do {
            programmes = .loaded(try await uncancellable { try await client.guide(for: channel, limit: 8) })
        } catch {
            if case .loaded = programmes { return }
            programmes = .failed(error.localizedDescription)
        }
    }
}

private struct ProgrammeRow: View {
    let programme: EPGProgramme
    let now: Date

    var body: some View {
        let onAir = programme.isOnAir(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(onAir ? "En ce moment" : airTime(programme.start))
                    .font(.caption.weight(onAir ? .semibold : .regular))
                    .foregroundStyle(onAir ? Color.accentColor : .secondary)
                    .monospacedDigit()
                Spacer()
                Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(programme.title)
                .font(onAir ? .headline : .body)
            if onAir {
                ProgressView(value: programme.progress(at: now))
            }
            if let summary = programme.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(onAir ? 4 : 2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Ligne d'une chaîne en direct d'un compte : l'émission en cours remplace le nom de la catégorie.
struct XtreamLiveRow: View {
    let channel: Channel
    let client: XtreamClient
    let isFavorite: Bool
    @State private var onAir: EPGProgramme?

    var body: some View {
        ChannelRow(channel: channel, isFavorite: isFavorite, detail: onAir.map(\.title))
            .task(id: channel.id) {
                // Seules les lignes affichées demandent leur guide, et la réponse reste en cache.
                onAir = try? await client.guide(for: channel, limit: 2).first { $0.isOnAir() }
            }
    }
}
