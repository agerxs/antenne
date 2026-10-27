import AntenneCore
import SwiftUI
import UniformTypeIdentifiers

struct AddPlaylistView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case link = "Lien"
        case file = "Fichier"
        var id: Self { self }
    }

    private static let playlistTypes: [UTType] = [
        .m3uPlaylist, UTType(filenameExtension: "m3u8"), .plainText,
    ].compactMap { $0 }

    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onAdded: (Playlist) -> Void

    @State private var mode: Mode = .link
    @State private var link = ""
    @State private var fileURL: URL?
    @State private var name = ""
    @State private var isImporterPresented = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Section {
                    switch mode {
                    case .link:
                        TextField("Lien M3U", text: $link, prompt: Text(verbatim: "http://fournisseur.com/get.php?…"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                    case .file:
                        Button { isImporterPresented = true } label: {
                            LabeledContent("Fichier", value: fileURL?.lastPathComponent ?? "Choisir…")
                        }
                    }
                } footer: {
                    Text(mode == .link
                         ? "Le lien M3U fourni avec ton abonnement. Il sera rechargé quand tu actualises la playlist."
                         : "Un fichier .m3u ou .m3u8. Ses chaînes sont copiées dans l'app.")
                }

                Section {
                    TextField("Nom", text: $name, prompt: Text("Facultatif"))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle("Nouvelle playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Ajouter") { Task { await add() } }
                            .disabled(!canSubmit)
                    }
                }
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: Self.playlistTypes) { result in
                switch result {
                case .success(let url): fileURL = url
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 340)
        #endif
    }

    private var remoteURL: URL? {
        let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https", url?.host() != nil else {
            return nil
        }
        return url
    }

    private var canSubmit: Bool {
        mode == .link ? remoteURL != nil : fileURL != nil
    }

    private func add() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let customName = name.trimmingCharacters(in: .whitespaces)
        do {
            let playlist: Playlist
            switch mode {
            case .link:
                guard let url = remoteURL else { return }
                playlist = try await store.addRemote(name: customName.isEmpty ? url.host() ?? "Playlist" : customName, url: url)
            case .file:
                guard let fileURL else { return }
                let fallback = fileURL.deletingPathExtension().lastPathComponent
                playlist = try await store.addFile(name: customName.isEmpty ? fallback : customName, contentsOf: fileURL)
            }
            onAdded(playlist)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
