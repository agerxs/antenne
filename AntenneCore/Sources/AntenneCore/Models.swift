import Foundation

public struct Channel: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var logoURL: URL?
    public var group: String?
    public var tvgID: String?
    /// Valeur de `#EXTVLCOPT:http-user-agent`, exigée par certains fournisseurs.
    public var userAgent: String?
    /// Identifiant de la chaîne en direct chez un serveur Xtream, pour son guide des programmes.
    public var streamID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        logoURL: URL? = nil,
        group: String? = nil,
        tvgID: String? = nil,
        userAgent: String? = nil,
        streamID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.logoURL = logoURL
        self.group = group
        self.tvgID = tvgID
        self.userAgent = userAgent
        self.streamID = streamID
    }
}

public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        case remote(URL)
        case file(name: String)
        /// Le mot de passe vit dans un `CredentialStore`, jamais dans ce fichier.
        case xtream(server: URL, username: String)
    }

    public var id: UUID
    public var name: String
    public var source: Source
    public var channelCount: Int
    public var updatedAt: Date
    /// Ordre d'affichage, identique sur tous les appareils (absent des playlists d'avant la synchronisation).
    public var addedAt: Date?

    public init(id: UUID = UUID(), name: String, source: Source, channelCount: Int, updatedAt: Date = .now, addedAt: Date? = .now) {
        self.id = id
        self.name = name
        self.source = source
        self.channelCount = channelCount
        self.updatedAt = updatedAt
        self.addedAt = addedAt
    }

    /// Une playlist importée d'un fichier n'existe que sur l'appareil qui a le fichier.
    public var isSyncable: Bool {
        if case .file = source { return false }
        return true
    }

    public var isRemote: Bool {
        switch source {
        case .remote, .xtream: true
        case .file: false
        }
    }

    public var isXtream: Bool {
        if case .xtream = source { return true }
        return false
    }
}
