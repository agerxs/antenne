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
        case .missingPassword: "Mot de passe introuvable pour ce compte sur cet appareil."
        case .keychain(let status): "Impossible d'enregistrer le mot de passe dans le trousseau (\(status))."
        case .invalidCredentials: "Utilisateur ou mot de passe refusé par le serveur."
        case .accountInactive(let status): "Ce compte n'est pas actif (statut : \(status))."
        case .badResponse: "Le serveur a répondu quelque chose d'illisible. Vérifie l'adresse du serveur."
        }
    }
}

/// Playlists, favoris et positions de lecture. Enregistrés en JSON dans Application Support
/// et, si un stockage iCloud est fourni, partagés entre les appareils.
@MainActor
@Observable
public final class PlaylistStore {
    public private(set) var refreshing: Set<Playlist.ID> = []
    private var library = Library()

    @ObservationIgnored private var channelCache: [Playlist.ID: [Channel]] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let cloud: CloudKeyValueStore?
    /// Journal de la synchronisation (nombres d'éléments seulement, jamais leur contenu).
    @ObservationIgnored public var onSyncEvent: ((String) -> Void)?

    nonisolated public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Antenne", directoryHint: .isDirectory)
    }

    nonisolated public static var defaultCacheDirectory: URL {
        URL.cachesDirectory.appending(path: "Antenne", directoryHint: .isDirectory)
    }

    static let progressLimit = 300

    public init(
        directory: URL = PlaylistStore.defaultDirectory,
        session: URLSession = .shared,
        credentials: CredentialStore = KeychainCredentialStore(),
        cacheDirectory: URL = PlaylistStore.defaultCacheDirectory,
        cloud: CloudKeyValueStore? = nil
    ) {
        self.directory = directory
        self.session = session
        self.credentials = credentials
        self.cacheDirectory = cacheDirectory
        self.cloud = cloud
        try? FileManager.default.createDirectory(at: channelsDirectory, withIntermediateDirectories: true)

        if let saved = Self.read(Library.self, from: libraryFile) {
            library = saved
        } else {
            library = migrateLegacyFiles()
            persist()
        }

        // Les comptes passent par l'API : une ancienne copie de leur playlist complète ne sert plus.
        for playlist in playlists where playlist.isXtream {
            try? FileManager.default.removeItem(at: channelsFile(playlist.id))
        }

        pullFromCloud()
    }

    // MARK: Lecture de l'état

    public var playlists: [Playlist] {
        library.playlists.values.compactMap(\.value).sorted {
            ($0.addedAt ?? .distantPast, $0.name) < ($1.addedAt ?? .distantPast, $1.name)
        }
    }

    public var favorites: [Channel] {
        library.favorites.values
            .compactMap { entry in entry.value.map { (entry.modifiedAt, $0) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    public func channels(in id: Playlist.ID) -> [Channel] {
        guard playlist(id) != nil else { return [] }
        if let cached = channelCache[id] { return cached }
        let loaded = Self.read([Channel].self, from: channelsFile(id)) ?? []
        channelCache[id] = loaded
        return loaded
    }

    // MARK: Playlists

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
        update(playlist)
        return playlist
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

    /// Client du compte, ou nil si ce n'est pas un compte ou que son mot de passe manque sur cet appareil.
    public func xtreamClient(for id: Playlist.ID) -> XtreamClient? {
        guard let playlist = playlist(id),
              case .xtream(let server, let username) = playlist.source,
              let password = credentials.password(for: id) else { return nil }
        return XtreamClient(server: server, username: username, password: password, session: session, cacheDirectory: cacheDirectory)
    }

    /// Client du compte d'où vient une chaîne (utile pour un favori, qui ne connaît pas sa playlist).
    public func xtreamClient(for channel: Channel) -> XtreamClient? {
        for playlist in playlists {
            guard case .xtream(let server, let username) = playlist.source,
                  channel.url.host() == server.host(), channel.url.port == server.port,
                  channel.url.pathComponents.contains(username) else { continue }
            return xtreamClient(for: playlist.id)
        }
        return nil
    }

    /// Ressaisie du mot de passe sur un appareil où il n'est pas arrivé (trousseau iCloud désactivé).
    public func setPassword(_ password: String, for id: Playlist.ID) throws {
        try credentials.setPassword(password, for: id)
        touch(id)
    }

    public func hasPassword(for id: Playlist.ID) -> Bool {
        credentials.password(for: id) != nil
    }

    public func refresh(_ id: Playlist.ID) async throws {
        guard let playlist = playlist(id), !refreshing.contains(id) else { return }

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
        guard var current = self.playlist(id) else { return }
        try Self.write(channels, to: channelsFile(id))
        channelCache[id] = channels
        current.channelCount = channels.count
        current.updatedAt = .now
        update(current, isChange: false)
    }

    public func rename(_ id: Playlist.ID, to name: String) {
        guard var playlist = playlist(id), let name = name.nilIfBlank else { return }
        playlist.name = name
        update(playlist)
    }

    public func delete(_ id: Playlist.ID) {
        xtreamClient(for: id)?.clearCache()
        credentials.removePassword(for: id)
        library.playlists[id.uuidString] = .init(value: nil, modifiedAt: .now)
        removeLocalFiles(of: id)
        save()
    }

    // MARK: Favoris

    public func isFavorite(_ channel: Channel) -> Bool {
        library.favorites[channel.syncKey]?.value != nil
    }

    public func toggleFavorite(_ channel: Channel) {
        let isFavorite = isFavorite(channel)
        library.favorites[channel.syncKey] = .init(value: isFavorite ? nil : channel, modifiedAt: .now)
        save()
    }

    // MARK: Reprise de lecture

    public func progress(for channel: Channel) -> PlaybackProgress? {
        library.progress[channel.syncKey]?.value
    }

    /// Note où en est un film ou un épisode. Le direct (sans durée) et les extraits sont ignorés.
    public func recordProgress(_ channel: Channel, position: Double, duration: Double) {
        guard PlaybackProgress.isTrackable(duration: duration), position.isFinite, position >= 0 else { return }
        let key = channel.syncKey
        // Quelques secondes regardées par erreur ne doivent pas créer d'entrée.
        if library.progress[key]?.value == nil, position < 10 { return }
        library.progress[key] = .init(value: PlaybackProgress(position: position, duration: duration), modifiedAt: .now)
        library.pruneProgress(keeping: Self.progressLimit)
        save()
    }

    // MARK: iCloud

    private static let cloudKeys = (playlists: "playlists", favorites: "favorites", progress: "progress")

    /// Fusionne ce qu'ont écrit les autres appareils, puis renvoie le résultat sur iCloud.
    /// À appeler au lancement et à chaque notification de changement d'iCloud ; chaque
    /// modification locale passe aussi par ici, pour ne jamais écraser un changement venu d'ailleurs.
    public func pullFromCloud() {
        guard let cloud else { return }
        var remote = Library()
        remote.playlists = Self.decode(cloud.data(forKey: Self.cloudKeys.playlists)) ?? [:]
        remote.favorites = Self.decode(cloud.data(forKey: Self.cloudKeys.favorites)) ?? [:]
        remote.progress = Self.decode(cloud.data(forKey: Self.cloudKeys.progress)) ?? [:]

        let before = library
        var merged = library
        let taken = merged.merge(remote)
        if !taken.isEmpty || merged.favorites != library.favorites || merged.progress != library.progress {
            onSyncEvent?("reçu d'iCloud : \(remote.playlists.count) playlist(s), \(remote.favorites.count) favori(s), \(remote.progress.count) position(s) ; \(taken.count) playlist(s) prise(s)")
        }
        merged.pruneProgress(keeping: Self.progressLimit)

        for key in taken {
            guard let id = UUID(uuidString: key) else { continue }
            if var incoming = merged.playlists[key]?.value, let local = before.playlists[key]?.value {
                // Le nombre de chaînes et la date d'actualisation restent propres à cet appareil.
                incoming.channelCount = local.channelCount
                incoming.updatedAt = local.updatedAt
                merged.playlists[key]?.value = incoming
            } else if merged.playlists[key]?.value == nil {
                removeLocalFiles(of: id)
            }
        }

        removeDuplicates(in: &merged)

        if merged != library {
            library = merged
            persist()
        }
        if Self.syncable(library) != remote {
            push()
        }

        // Une playlist M3U arrivée d'un autre appareil doit télécharger ses chaînes ici.
        for key in taken where before.playlists[key]?.value == nil {
            guard let playlist = library.playlists[key]?.value, case .remote = playlist.source else { continue }
            Task { try? await refresh(playlist.id) }
        }
    }

    /// La même playlist ajoutée séparément sur deux appareils : on garde la plus ancienne, partout
    /// la même, et le mot de passe suit si cet appareil ne connaissait que l'autre exemplaire.
    private func removeDuplicates(in library: inout Library) {
        let live = library.playlists.compactMap { key, entry in entry.value.map { (key, $0) } }
        for (_, copies) in Dictionary(grouping: live, by: { $0.1.source }) where copies.count > 1 {
            let ordered = copies.sorted { ($0.1.addedAt ?? .distantPast, $0.0) < ($1.1.addedAt ?? .distantPast, $1.0) }
            let kept = ordered[0].1
            for (key, duplicate) in ordered.dropFirst() {
                if let password = credentials.password(for: duplicate.id), credentials.password(for: kept.id) == nil {
                    try? credentials.setPassword(password, for: kept.id)
                }
                library.playlists[key] = .init(value: nil, modifiedAt: .now)
                removeLocalFiles(of: duplicate.id)
            }
        }
    }

    private func push() {
        guard let cloud else { return }
        let outgoing = Self.syncable(library)
        cloud.set(Self.encode(outgoing.playlists), forKey: Self.cloudKeys.playlists)
        cloud.set(Self.encode(outgoing.favorites), forKey: Self.cloudKeys.favorites)
        cloud.set(Self.encode(outgoing.progress), forKey: Self.cloudKeys.progress)
        let accepted = cloud.synchronize()
        onSyncEvent?("envoyé vers iCloud : \(outgoing.playlists.count) playlist(s), \(outgoing.favorites.count) favori(s), \(outgoing.progress.count) position(s) ; synchronize=\(accepted)")
    }

    /// Ce qui part sur iCloud : tout, sauf les playlists importées d'un fichier.
    private static func syncable(_ library: Library) -> Library {
        var outgoing = library
        outgoing.playlists = library.playlists.filter { $0.value.value?.isSyncable ?? true }
        return outgoing
    }

    // MARK: Privé

    private func playlist(_ id: Playlist.ID) -> Playlist? {
        library.playlists[id.uuidString]?.value
    }

    /// `isChange: false` pour une donnée propre à l'appareil (actualisation) : elle ne doit pas
    /// l'emporter sur un renommage fait ailleurs.
    private func update(_ playlist: Playlist, isChange: Bool = true) {
        let key = playlist.id.uuidString
        let date = isChange ? Date.now : (library.playlists[key]?.modifiedAt ?? .now)
        library.playlists[key] = .init(value: playlist, modifiedAt: date)
        save()
    }

    private func touch(_ id: Playlist.ID) {
        guard var playlist = playlist(id) else { return }
        playlist.updatedAt = .now
        update(playlist, isChange: false)
    }

    private func insert(_ playlist: Playlist, channels: [Channel]) throws -> Playlist {
        try Self.write(channels, to: channelsFile(playlist.id))
        channelCache[playlist.id] = channels
        update(playlist)
        return playlist
    }

    private func removeLocalFiles(of id: Playlist.ID) {
        channelCache[id] = nil
        try? FileManager.default.removeItem(at: channelsFile(id))
    }

    private func save() {
        persist()
        pullFromCloud()
    }

    private func persist() {
        try? Self.write(library, to: libraryFile)
    }

    /// Reprend les fichiers d'avant la synchronisation, en gardant l'ordre des playlists et des favoris.
    private func migrateLegacyFiles() -> Library {
        var migrated = Library()
        let legacyPlaylists = Self.read([Playlist].self, from: directory.appending(path: "playlists.json")) ?? []
        for (index, var playlist) in legacyPlaylists.enumerated() {
            playlist.addedAt = playlist.addedAt ?? Date(timeIntervalSince1970: Double(index))
            migrated.playlists[playlist.id.uuidString] = .init(value: playlist, modifiedAt: .distantPast)
        }
        let legacyFavorites = Self.read([Channel].self, from: directory.appending(path: "favorites.json")) ?? []
        for (index, channel) in legacyFavorites.enumerated() {
            migrated.favorites[channel.syncKey] = .init(value: channel, modifiedAt: Date(timeIntervalSince1970: Double(index)))
        }
        try? FileManager.default.removeItem(at: directory.appending(path: "playlists.json"))
        try? FileManager.default.removeItem(at: directory.appending(path: "favorites.json"))
        return migrated
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

    private var libraryFile: URL { directory.appending(path: "library.json") }
    private var channelsDirectory: URL { directory.appending(path: "channels", directoryHint: .isDirectory) }
    private func channelsFile(_ id: Playlist.ID) -> URL { channelsDirectory.appending(path: "\(id.uuidString).json") }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
