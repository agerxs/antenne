import Foundation
import Observation

public enum PlaylistError: LocalizedError, Equatable {
    case empty
    case unreadable
    case http(Int)
    case missingPassword
    case keychain(OSStatus)
    case invalidCredentials
    case accountInactive(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .empty: "Aucune chaîne trouvée dans cette playlist."
        case .unreadable: "Impossible de lire ce fichier."
        case .http(let code): "Le serveur a refusé la playlist (code \(code)). Vérifie le lien ou ton abonnement."
        case .missingPassword: "Mot de passe introuvable pour ce compte. Supprime-le puis ajoute-le à nouveau."
        case .keychain(let status): "Impossible d'enregistrer le mot de passe dans le trousseau (\(status))."
        case .invalidCredentials: "Utilisateur ou mot de passe refusé par le serveur."
        case .accountInactive(let status): "Ce compte n'est pas actif (statut : \(status))."
        case .badResponse: "Le serveur a répondu quelque chose d'illisible. Vérifie l'adresse du serveur."
        }
    }
}

/// Playlists, chaînes et favoris, enregistrés en JSON dans Application Support.
@MainActor
@Observable
public final class PlaylistStore {
    public private(set) var playlists: [Playlist] = []
    public private(set) var favorites: [Channel] = []
    public private(set) var refreshing: Set<Playlist.ID> = []

    @ObservationIgnored private var channelCache: [Playlist.ID: [Channel]] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let cacheDirectory: URL

    nonisolated public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Antenne", directoryHint: .isDirectory)
    }

    nonisolated public static var defaultCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "Antenne", directoryHint: .isDirectory)
    }

    public init(
        directory: URL = PlaylistStore.defaultDirectory,
        session: URLSession = .shared,
        credentials: CredentialStore = KeychainCredentialStore(),
        cacheDirectory: URL = PlaylistStore.defaultCacheDirectory
    ) {
        self.directory = directory
        self.session = session
        self.credentials = credentials
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: channelsDirectory, withIntermediateDirectories: true)
        playlists = Self.read([Playlist].self, from: playlistsFile) ?? []
        favorites = Self.read([Channel].self, from: favoritesFile) ?? []

        // Les comptes passent désormais par l'API : l'ancienne copie de la playlist complète ne sert plus.
        for playlist in playlists where playlist.isXtream {
            try? FileManager.default.removeItem(at: channelsFile(playlist.id))
        }
    }

    // MARK: Playlists

    public func channels(in id: Playlist.ID) -> [Channel] {
        guard playlists.contains(where: { $0.id == id }) else { return [] }
        if let cached = channelCache[id] { return cached }
        let loaded = Self.read([Channel].self, from: channelsFile(id)) ?? []
        channelCache[id] = loaded
        return loaded
    }

    @discardableResult
    public func addRemote(name: String, url: URL) async throws -> Playlist {
        let channels = try await download(url)
        return try insert(Playlist(name: name, source: .remote(url), channelCount: channels.count), channels: channels)
    }

    @discardableResult
    public func addXtream(name: String, server: URL, username: String, password: String) async throws -> Playlist {
        let client = XtreamClient(server: server, username: username, password: password, session: session, cacheDirectory: cacheDirectory)
        let account = try await client.accountInfo(forceRefresh: true)
        guard account.isActive else { throw PlaylistError.accountInactive(account.status) }

        let playlist = Playlist(name: name, source: .xtream(server: server, username: username), channelCount: 0)
        try credentials.setPassword(password, for: playlist.id)
        playlists.append(playlist)
        persistPlaylists()
        return playlist
    }

    /// Client du compte, ou nil si ce n'est pas un compte ou que son mot de passe a disparu.
    public func xtreamClient(for id: Playlist.ID) -> XtreamClient? {
        guard let playlist = playlists.first(where: { $0.id == id }),
              case .xtream(let server, let username) = playlist.source,
              let password = credentials.password(for: id) else { return nil }
        return XtreamClient(server: server, username: username, password: password, session: session, cacheDirectory: cacheDirectory)
    }

    @discardableResult
    public func addFile(name: String, contentsOf fileURL: URL) async throws -> Playlist {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else { throw PlaylistError.unreadable }

        let channels = try await Self.parse(data)
        let source = Playlist.Source.file(name: fileURL.lastPathComponent)
        return try insert(Playlist(name: name, source: source, channelCount: channels.count), channels: channels)
    }

    public func refresh(_ id: Playlist.ID) async throws {
        guard let playlist = playlists.first(where: { $0.id == id }), !refreshing.contains(id) else { return }

        let url: URL
        switch playlist.source {
        case .remote(let remote):
            url = remote
        case .xtream:
            // Les listes se rechargent à la demande : vider le cache suffit.
            guard let client = xtreamClient(for: id) else { throw PlaylistError.missingPassword }
            client.clearCache()
            touch(id)
            return
        case .file:
            return
        }

        refreshing.insert(id)
        defer { refreshing.remove(id) }

        let channels = try await download(url)
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        try Self.write(channels, to: channelsFile(id))
        channelCache[id] = channels
        playlists[index].channelCount = channels.count
        touch(id)
    }

    private func touch(_ id: Playlist.ID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].updatedAt = .now
        persistPlaylists()
    }

    public func rename(_ id: Playlist.ID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              let name = name.nilIfBlank else { return }
        playlists[index].name = name
        persistPlaylists()
    }

    public func delete(_ id: Playlist.ID) {
        xtreamClient(for: id)?.clearCache()
        playlists.removeAll { $0.id == id }
        channelCache[id] = nil
        credentials.removePassword(for: id)
        try? FileManager.default.removeItem(at: channelsFile(id))
        persistPlaylists()
    }

    // MARK: Favoris

    public func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains { $0.url == channel.url }
    }

    public func toggleFavorite(_ channel: Channel) {
        if isFavorite(channel) {
            favorites.removeAll { $0.url == channel.url }
        } else {
            favorites.append(channel)
        }
        try? Self.write(favorites, to: favoritesFile)
    }

    // MARK: Privé

    private func insert(_ playlist: Playlist, channels: [Channel]) throws -> Playlist {
        try Self.write(channels, to: channelsFile(playlist.id))
        channelCache[playlist.id] = channels
        playlists.append(playlist)
        persistPlaylists()
        return playlist
    }

    private func download(_ url: URL) async throws -> [Channel] {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlaylistError.http(http.statusCode)
        }
        return try await Self.parse(data)
    }

    /// Hors du thread principal : certaines playlists dépassent les 50 000 chaînes.
    nonisolated private static func parse(_ data: Data) async throws -> [Channel] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let channels = M3UParser.parse(text)
        guard !channels.isEmpty else { throw PlaylistError.empty }
        return channels
    }

    private func persistPlaylists() {
        try? Self.write(playlists, to: playlistsFile)
    }

    private var playlistsFile: URL { directory.appending(path: "playlists.json") }
    private var favoritesFile: URL { directory.appending(path: "favorites.json") }
    private var channelsDirectory: URL { directory.appending(path: "channels", directoryHint: .isDirectory) }
    private func channelsFile(_ id: Playlist.ID) -> URL { channelsDirectory.appending(path: "\(id.uuidString).json") }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
