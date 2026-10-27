import AntenneCore
import SwiftUI

struct SidebarView: View {
    @Environment(PlaylistStore.self) private var store
    @Binding var selection: SidebarItem?
    @Binding var isAddingPlaylist: Bool

    @State private var renaming: Playlist?
    @State private var newName = ""
    @State private var pendingDeletion: Playlist?
    @State private var errorMessage: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarItem.favorites) {
                    Label("Favoris", systemImage: "star")
                }
                .badge(store.favorites.count)
            }

            Section("Playlists") {
                ForEach(store.playlists) { playlist in
                    NavigationLink(value: SidebarItem.playlist(playlist.id)) {
                        PlaylistRow(playlist: playlist, isRefreshing: store.refreshing.contains(playlist.id))
                    }
                    .contextMenu { actions(for: playlist) }
                    #if os(iOS)
                    .swipeActions {
                        Button(role: .destructive) { pendingDeletion = playlist } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        if playlist.isRemote {
                            Button { refresh(playlist) } label: {
                                Label("Actualiser", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    #endif
                }

                if store.playlists.isEmpty {
                    // Sans style « borderless », la sélection de la liste avale le tap sur iOS.
                    Button { isAddingPlaylist = true } label: {
                        Label("Ajouter une playlist", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("Antenne")
        .toolbar {
            ToolbarItem {
                Button { isAddingPlaylist = true } label: {
                    Label("Ajouter une playlist", systemImage: "plus")
                }
                .keyboardShortcut("n")
            }
        }
        .alert("Renommer la playlist", isPresented: isPresented($renaming)) {
            TextField("Nom", text: $newName)
            Button("Annuler", role: .cancel) {}
            Button("Renommer") {
                if let renaming { store.rename(renaming.id, to: newName) }
            }
        }
        .confirmationDialog(
            "Supprimer « \(pendingDeletion?.name ?? "") » ?",
            isPresented: isPresented($pendingDeletion),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let pendingDeletion { store.delete(pendingDeletion.id) }
            }
        } message: {
            Text("Ses chaînes disparaîtront de l'app. Tes favoris restent.")
        }
        .alert("Actualisation impossible", isPresented: isPresented($errorMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func actions(for playlist: Playlist) -> some View {
        if playlist.isRemote {
            Button { refresh(playlist) } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
        }
        Button {
            newName = playlist.name
            renaming = playlist
        } label: {
            Label("Renommer", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) { pendingDeletion = playlist } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }

    private func refresh(_ playlist: Playlist) {
        Task {
            do { try await store.refresh(playlist.id) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let isRefreshing: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var summary: String {
        if case .xtream(_, let username) = playlist.source {
            return "Compte \(username) · Direct, films, séries"
        }
        let count = playlist.channelCount.formatted()
        let noun = playlist.channelCount > 1 ? "chaînes" : "chaîne"
        let date = playlist.updatedAt.formatted(.relative(presentation: .named))
        return "\(count) \(noun) · \(date)"
    }
}
