import AntenneCore
import SwiftUI

enum SidebarItem: Hashable {
    case favorites
    case playlist(Playlist.ID)
}

struct ContentView: View {
    @Environment(PlaylistStore.self) private var store
    @State private var sidebarSelection: SidebarItem?
    @State private var selectedChannel: Channel?
    @State private var isAddingPlaylist = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection, isAddingPlaylist: $isAddingPlaylist)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            channelColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let selectedChannel {
                PlayerView(channel: selectedChannel)
            } else {
                ContentUnavailableView(
                    "Aucune chaîne en lecture",
                    systemImage: "play.rectangle",
                    description: Text("Choisis une chaîne dans la liste.")
                )
            }
        }
        .sheet(isPresented: $isAddingPlaylist) {
            AddPlaylistView { playlist in
                sidebarSelection = .playlist(playlist.id)
            }
        }
        .onChange(of: sidebarSelection) {
            selectedChannel = nil
        }
        .onChange(of: store.playlists) {
            if case .playlist(let id) = sidebarSelection, !store.playlists.contains(where: { $0.id == id }) {
                sidebarSelection = nil
            }
        }
        .task {
            if sidebarSelection == nil, let first = store.playlists.first {
                sidebarSelection = .playlist(first.id)
            }
        }
    }

    #if os(macOS)
    private static let favoritesHint = "Ajoute une chaîne aux favoris depuis sa fiche ou avec un clic droit."
    #else
    private static let favoritesHint = "Ajoute une chaîne aux favoris depuis sa fiche ou en glissant sa ligne vers la droite."
    #endif

    @ViewBuilder
    private var channelColumn: some View {
        switch sidebarSelection {
        case .favorites:
            ChannelListView(
                title: "Favoris",
                channels: store.favorites,
                selection: $selectedChannel,
                emptyTitle: "Aucun favori",
                emptyMessage: Self.favoritesHint
            )
        case .playlist(let id):
            if let playlist = store.playlists.first(where: { $0.id == id }) {
                ChannelListView(
                    title: playlist.name,
                    channels: store.channels(in: id),
                    selection: $selectedChannel,
                    emptyTitle: "Playlist vide",
                    emptyMessage: "Actualise-la depuis la barre latérale."
                )
                .id(id)
            }
        case nil:
            if store.playlists.isEmpty {
                ContentUnavailableView {
                    Label("Aucune playlist", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Ajoute le lien M3U de ton abonnement ou importe un fichier .m3u.")
                } actions: {
                    Button("Ajouter une playlist") { isAddingPlaylist = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Choisis une playlist", systemImage: "sidebar.left")
            }
        }
    }
}
