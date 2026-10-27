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

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        logoURL: URL? = nil,
        group: String? = nil,
        tvgID: String? = nil,
        userAgent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.logoURL = logoURL
        self.group = group
        self.tvgID = tvgID
        self.userAgent = userAgent
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

    public init(id: UUID = UUID(), name: String, source: Source, channelCount: Int, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.source = source
        self.channelCount = channelCount
        self.updatedAt = updatedAt
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
