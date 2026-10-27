import AntenneCore
import SwiftUI
import UniformTypeIdentifiers

struct AddPlaylistView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case account = "Compte"
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

    @State private var mode: Mode = .account
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
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
                    case .account:
                        TextField("Serveur", text: $server, prompt: Text(verbatim: "http://serveur.com:8080"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Utilisateur", text: $username, prompt: Text("Nom d'utilisateur"))
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        SecureField("Mot de passe", text: $password, prompt: Text("Mot de passe"))
                            .textContentType(.password)
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
                    Text(footer)
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

    private var footer: String {
        switch mode {
        case .account: "Les identifiants Xtream Codes de ton abonnement. Le mot de passe est rangé dans le trousseau."
        case .link: "Le lien M3U fourni avec ton abonnement. Il sera rechargé quand tu actualises la playlist."
        case .file: "Un fichier .m3u ou .m3u8. Ses chaînes sont copiées dans l'app."
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .account: Xtream.serverURL(from: server) != nil && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .link: remoteURL != nil
        case .file: fileURL != nil
        }
    }

    private func add() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let customName = name.trimmingCharacters(in: .whitespaces)
        do {
            let playlist: Playlist
            switch mode {
            case .account:
                guard let serverURL = Xtream.serverURL(from: server) else { return }
                playlist = try await store.addXtream(
                    name: customName.isEmpty ? serverURL.host() ?? "Compte" : customName,
                    server: serverURL,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
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
