import AntenneCore
import SwiftUI

struct ChannelListView: View {
    @Environment(PlaylistStore.self) private var store

    let title: String
    let channels: [Channel]
    @Binding var selection: DetailItem?
    let emptyTitle: String
    let emptyMessage: String

    @State private var searchText = ""
    @State private var group: String?

    var body: some View {
        let visible = filteredChannels
        List(selection: $selection) {
            ForEach(visible) { channel in
                NavigationLink(value: DetailItem.channel(channel)) {
                    ChannelRow(channel: channel, isFavorite: store.isFavorite(channel), progress: store.progress(for: channel))
                }
                .contextMenu { FavoriteButton(channel: channel) }
                #if os(iOS)
                .swipeActions(edge: .leading) { FavoriteButton(channel: channel).tint(.yellow) }
                #endif
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        .navigationSubtitle(subtitle(visible.count))
        #endif
        .searchable(text: $searchText, prompt: "Rechercher une chaîne")
        .toolbar {
            if groups.count > 1 {
                ToolbarItem {
                    Menu {
                        Picker("Groupe", selection: $group) {
                            Text("Tous les groupes").tag(String?.none)
                            Divider()
                            ForEach(groups, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(group ?? "Groupes", systemImage: group == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .overlay {
            if channels.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tv", description: Text(emptyMessage))
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var groups: [String] {
        var seen = Set<String>()
        return channels.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    private var filteredChannels: [Channel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return channels.filter { channel in
            (group == nil || channel.group == group)
                && (query.isEmpty || channel.name.localizedStandardContains(query))
        }
    }

    private func subtitle(_ count: Int) -> String {
        "\(count.formatted()) \(count > 1 ? "chaînes" : "chaîne")"
    }

}

struct FavoriteButton: View {
    @Environment(PlaylistStore.self) private var store
    let channel: Channel

    var body: some View {
        let isFavorite = store.isFavorite(channel)
        Button { store.toggleFavorite(channel) } label: {
            Label(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
                  systemImage: isFavorite ? "star.slash" : "star")
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isFavorite: Bool
    /// Remplace le groupe sous le nom (l'émission en cours d'une chaîne en direct, par exemple).
    var detail: String? = nil
    var progress: PlaybackProgress? = nil

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logoURL, name: channel.name)
                .frame(width: 56, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .lineLimit(1)
                if let subtitle = detail ?? channel.group {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        .padding(.vertical, 2)
    }
}

/// « Vu », ou la part déjà regardée d'un film ou d'un épisode.
struct ProgressBadge: View {
    let progress: PlaybackProgress

    var body: some View {
        if progress.isFinished {
            Label("Vu", systemImage: "checkmark")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 120)
                .accessibilityLabel("Déjà regardé à \(Int(progress.fraction * 100)) %")
        }
    }
}

struct ChannelLogo: View {
    let url: URL?
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(4)
                    } else {
                        Text(initials)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
