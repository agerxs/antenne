import CryptoKit
import Foundation

/// Où en est la lecture d'un film ou d'un épisode, en secondes.
public struct PlaybackProgress: Codable, Equatable, Sendable {
    public var position: Double
    public var duration: Double

    public init(position: Double, duration: Double) {
        self.position = position
        self.duration = duration
    }

    public var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }
    public var isFinished: Bool { fraction >= Self.finishedFraction }

    /// Au-delà, le générique est entamé : on considère le titre comme vu.
    static let finishedFraction = 0.95
    /// En deçà, reprendre n'apporte rien : on repart du début.
    static let minimumResumePosition: Double = 30
    /// Le direct n'a pas de durée ; un extrait de moins d'une minute ne mérite pas d'être suivi.
    static let minimumTrackedDuration: Double = 60

    /// Position à laquelle reprendre, ou nil pour lire depuis le début.
    public var resumePosition: Double? {
        position >= Self.minimumResumePosition && !isFinished ? position : nil
    }

    static func isTrackable(duration: Double) -> Bool {
        duration.isFinite && duration >= minimumTrackedDuration
    }
}

/// Tout ce qui se synchronise entre appareils. Chaque entrée garde sa date de modification
/// et une suppression laisse une trace : sans elle, l'autre appareil recréerait l'élément.
public struct Library: Codable, Equatable, Sendable {
    public struct Entry<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        /// nil quand l'élément a été supprimé.
        public var value: Value?
        public var modifiedAt: Date

        public init(value: Value?, modifiedAt: Date) {
            self.value = value
            self.modifiedAt = modifiedAt
        }
    }

    public var playlists: [String: Entry<Playlist>] = [:]
    public var favorites: [String: Entry<Channel>] = [:]
    public var progress: [String: Entry<PlaybackProgress>] = [:]

    public init() {}

    /// Garde, pour chaque élément, la version la plus récente des deux côtés.
    /// Renvoie les clés de playlists prises chez l'autre.
    @discardableResult
    public mutating func merge(_ other: Library) -> Set<String> {
        let playlistKeys = Self.merge(&playlists, other.playlists)
        Self.merge(&favorites, other.favorites)
        Self.merge(&progress, other.progress)
        return playlistKeys
    }

    @discardableResult
    static func merge<Value>(_ local: inout [String: Entry<Value>], _ remote: [String: Entry<Value>]) -> Set<String> {
        var taken = Set<String>()
        for (key, entry) in remote {
            if let current = local[key], current.modifiedAt >= entry.modifiedAt { continue }
            local[key] = entry
            taken.insert(key)
        }
        return taken
    }

    /// Les positions de lecture s'accumulent : seules les plus récentes sont gardées.
    mutating func pruneProgress(keeping limit: Int) {
        guard progress.count > limit else { return }
        let kept = progress.sorted { $0.value.modifiedAt > $1.value.modifiedAt }.prefix(limit)
        progress = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

extension Channel {
    /// Clé stable d'une chaîne d'un appareil à l'autre, sans exposer son lien (qui peut contenir un mot de passe).
    public var syncKey: String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stockage clé-valeur partagé entre appareils (iCloud), remplaçable dans les tests.
public protocol CloudKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}
