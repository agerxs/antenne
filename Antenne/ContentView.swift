import AntenneCore
import SwiftUI

enum SidebarItem: Hashable {
    case favorites
    case playlist(Playlist.ID)
}

/// Ce que montre la colonne de droite : une chaîne à lire ou la fiche d'une série.
enum DetailItem: Hashable {
    case channel(Channel)
    case series(XtreamSeries, playlistID: Playlist.ID)
}

struct ContentView: View {
    @Environment(PlaylistStore.self) private var store
    @State private var sidebarSelection: SidebarItem?
    @State private var detailItem: DetailItem?
    @State private var isAddingPlaylist = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection, isAddingPlaylist: $isAddingPlaylist)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            channelColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            // Pile propre à la colonne : une série pousse ses épisodes, puis le lecteur.
            NavigationStack {
                switch detailItem {
                case .channel(let channel):
                    PlayerView(channel: channel)
                case .series(let series, let playlistID):
                    if let client = store.xtreamClient(for: playlistID) {
                        SeriesDetailView(series: series, client: client)
                    }
                case nil:
                    ContentUnavailableView(
                        "Aucune chaîne en lecture",
                        systemImage: "play.rectangle",
                        description: Text("Choisis une chaîne, un film ou une série dans la liste.")
                    )
                }
            }
            .id(detailItem)
        }
        .sheet(isPresented: $isAddingPlaylist) {
            AddPlaylistView { playlist in
                sidebarSelection = .playlist(playlist.id)
            }
        }
        .onChange(of: sidebarSelection) {
            detailItem = nil
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
                selection: $detailItem,
                emptyTitle: "Aucun favori",
                emptyMessage: Self.favoritesHint
            )
        case .playlist(let id):
            if let playlist = store.playlists.first(where: { $0.id == id }) {
                if playlist.isXtream {
                    if let client = store.xtreamClient(for: id) {
                        XtreamBrowserView(playlist: playlist, client: client, selection: $detailItem)
                            .id(id)
                    } else {
                        ContentUnavailableView(
                            "Mot de passe introuvable",
                            systemImage: "key",
                            description: Text("Supprime ce compte puis ajoute-le à nouveau.")
                        )
                    }
                } else {
                    ChannelListView(
                        title: playlist.name,
                        channels: store.channels(in: id),
                        selection: $detailItem,
                        emptyTitle: "Playlist vide",
                        emptyMessage: "Actualise-la depuis la barre latérale."
                    )
                    .id(id)
                }
            }
        case nil:
            if store.playlists.isEmpty {
                ContentUnavailableView {
                    Label("Aucune playlist", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Ajoute ton compte IPTV, un lien M3U ou un fichier .m3u.")
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
