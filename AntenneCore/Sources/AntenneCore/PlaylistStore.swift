import Foundation
import Observation

public enum PlaylistError: LocalizedError, Equatable {
    case empty
    case unreadable
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "Aucune chaîne trouvée dans cette playlist."
        case .unreadable: "Impossible de lire ce fichier."
        case .http(let code): "Le serveur a refusé la playlist (code \(code)). Vérifie le lien ou ton abonnement."
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

    nonisolated public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Antenne", directoryHint: .isDirectory)
    }

    public init(directory: URL = PlaylistStore.defaultDirectory, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        try? FileManager.default.createDirectory(at: channelsDirectory, withIntermediateDirectories: true)
        playlists = Self.read([Playlist].self, from: playlistsFile) ?? []
        favorites = Self.read([Channel].self, from: favoritesFile) ?? []
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
    public func addFile(name: String, contentsOf fileURL: URL) async throws -> Playlist {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else { throw PlaylistError.unreadable }

        let channels = try await Self.parse(data)
        let source = Playlist.Source.file(name: fileURL.lastPathComponent)
        return try insert(Playlist(name: name, source: source, channelCount: channels.count), channels: channels)
    }

    public func refresh(_ id: Playlist.ID) async throws {
        guard let playlist = playlists.first(where: { $0.id == id }),
              case .remote(let url) = playlist.source,
              !refreshing.contains(id) else { return }

        refreshing.insert(id)
        defer { refreshing.remove(id) }

        let channels = try await download(url)
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        try Self.write(channels, to: channelsFile(id))
        channelCache[id] = channels
        playlists[index].channelCount = channels.count
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
        playlists.removeAll { $0.id == id }
        channelCache[id] = nil
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
