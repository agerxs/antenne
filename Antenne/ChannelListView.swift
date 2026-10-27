import AntenneCore
import SwiftUI

struct ChannelListView: View {
    @Environment(PlaylistStore.self) private var store

    let title: String
    let channels: [Channel]
    @Binding var selection: Channel?
    let emptyTitle: String
    let emptyMessage: String

    @State private var searchText = ""
    @State private var group: String?

    var body: some View {
        let visible = filteredChannels
        List(selection: $selection) {
            ForEach(visible) { channel in
                NavigationLink(value: channel) {
                    ChannelRow(channel: channel, isFavorite: store.isFavorite(channel))
                }
                .contextMenu { favoriteButton(for: channel) }
                #if os(iOS)
                .swipeActions(edge: .leading) { favoriteButton(for: channel).tint(.yellow) }
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

    private func favoriteButton(for channel: Channel) -> some View {
        let isFavorite = store.isFavorite(channel)
        return Button { store.toggleFavorite(channel) } label: {
            Label(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
                  systemImage: isFavorite ? "star.slash" : "star")
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logoURL, name: channel.name)
                .frame(width: 56, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .lineLimit(1)
                if let group = channel.group {
                    Text(group)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

private struct ChannelLogo: View {
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
