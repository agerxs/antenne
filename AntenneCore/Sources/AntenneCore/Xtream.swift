import CryptoKit
import Foundation

/// Abonnements « Xtream Codes » : un serveur, un identifiant et un mot de passe.
public enum Xtream {
    /// Accepte « serveur.com:8080 » comme « http://serveur.com:8080/ ».
    public static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "" : "/" + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func encode(_ value: String) -> String {
        // « + » serait lu comme une espace par la plupart des serveurs.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: Modèles

public enum XtreamContentKind: String, CaseIterable, Hashable, Sendable {
    case live, movies, series

    var categoriesAction: String {
        switch self {
        case .live: "get_live_categories"
        case .movies: "get_vod_categories"
        case .series: "get_series_categories"
        }
    }
}

public struct XtreamCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct XtreamSeries: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let coverURL: URL?
    public let plot: String?
    public let genre: String?
    public let releaseDate: String?
    public let rating: String?
}

public struct XtreamEpisode: Identifiable, Hashable, Sendable {
    public let number: Int?
    public let title: String
    public let duration: String?
    public let channel: Channel
    public var id: Channel.ID { channel.id }
}

public struct XtreamSeason: Identifiable, Hashable, Sendable {
    public let number: Int
    public let episodes: [XtreamEpisode]
    public var id: Int { number }
}

public struct XtreamSeriesDetail: Sendable {
    public let plot: String?
    public let cast: String?
    public let genre: String?
    public let releaseDate: String?
    public let coverURL: URL?
    public let seasons: [XtreamSeason]
}

/// Une émission du guide des programmes.
public struct EPGProgramme: Identifiable, Hashable, Sendable {
    public let title: String
    public let summary: String?
    public let start: Date
    public let end: Date

    public var id: String { "\(start.timeIntervalSince1970)-\(title)" }

    public func isOnAir(at date: Date = .now) -> Bool { start <= date && date < end }

    /// Part écoulée de l'émission, de 0 à 1.
    public func progress(at date: Date = .now) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }
}

public struct XtreamAccountInfo: Equatable, Sendable {
    public let status: String
    public let isTrial: Bool
    public let expiresAt: Date?
    public let activeConnections: Int?
    public let maxConnections: Int?

    public var isActive: Bool { status.lowercased() == "active" }
}

// MARK: Client

/// Interroge `player_api.php` catégorie par catégorie, au lieu de la playlist complète
/// (plusieurs centaines de milliers d'entrées chez certains fournisseurs).
public struct XtreamClient: Sendable {
    public let server: URL
    public let username: String
    private let password: String
    private let session: URLSession
    private let cacheDirectory: URL?

    public init(server: URL, username: String, password: String, session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.server = server
        self.username = username
        self.password = password
        self.session = session
        // Le dossier dépend du compte sans contenir l'identifiant en clair.
        self.cacheDirectory = cacheDirectory?.appending(
            path: Self.digest("\(server.absoluteString)|\(username)"), directoryHint: .isDirectory
        )
    }

    public func accountInfo(forceRefresh: Bool = false) async throws -> XtreamAccountInfo {
        try await load(action: nil, maxAge: 5 * 60, force: forceRefresh) { json in
            guard let info = (json as? [String: Any])?["user_info"] as? [String: Any] else {
                throw PlaylistError.badResponse
            }
            if int(info["auth"]) == 0 { throw PlaylistError.invalidCredentials }
            return XtreamAccountInfo(
                status: text(info["status"]) ?? "?",
                isTrial: int(info["is_trial"]) == 1,
                expiresAt: double(info["exp_date"]).map(Date.init(timeIntervalSince1970:)),
                activeConnections: int(info["active_cons"]),
                maxConnections: int(info["max_connections"])
            )
        }
    }

    public func categories(_ kind: XtreamContentKind, forceRefresh: Bool = false) async throws -> [XtreamCategory] {
        try await load(action: kind.categoriesAction, maxAge: 12 * 3600, force: forceRefresh) { json in
            records(json).compactMap { record in
                guard let id = text(record["category_id"]) else { return nil }
                return XtreamCategory(id: id, name: text(record["category_name"]) ?? "Sans nom")
            }
        }
    }

    /// Chaînes en direct ou films d'une catégorie, prêts à lire.
    public func channels(_ kind: XtreamContentKind, in category: XtreamCategory, forceRefresh: Bool = false) async throws -> [Channel] {
        precondition(kind != .series, "Les séries se chargent avec series(in:)")
        let action = kind == .live ? "get_live_streams" : "get_vod_streams"
        return try await load(action: action, extra: [("category_id", category.id)], maxAge: 6 * 3600, force: forceRefresh) { json in
            records(json).compactMap { record in
                guard let id = text(record["stream_id"]) else { return nil }
                let url = kind == .live
                    ? streamURL("live", id: id, extension: "m3u8")
                    : streamURL("movie", id: id, extension: text(record["container_extension"]) ?? "mp4")
                return Channel(
                    id: UUID(stableFrom: "\(server.absoluteString)|\(kind.rawValue)|\(id)"),
                    name: text(record["name"]) ?? "Sans nom",
                    url: url,
                    logoURL: text(record["stream_icon"]).flatMap(URL.init(string:)),
                    group: category.name,
                    tvgID: text(record["epg_channel_id"]),
                    streamID: kind == .live ? id : nil
                )
            }
        }
    }

    public func series(in category: XtreamCategory, forceRefresh: Bool = false) async throws -> [XtreamSeries] {
        try await load(action: "get_series", extra: [("category_id", category.id)], maxAge: 6 * 3600, force: forceRefresh) { json in
            records(json).compactMap { record in
                guard let id = text(record["series_id"]) else { return nil }
                return XtreamSeries(
                    id: id,
                    name: text(record["name"]) ?? "Sans nom",
                    coverURL: text(record["cover"]).flatMap(URL.init(string:)),
                    plot: text(record["plot"]),
                    genre: text(record["genre"]),
                    releaseDate: text(record["releaseDate"]) ?? text(record["release_date"]),
                    rating: text(record["rating"])
                )
            }
        }
    }

    public func seriesDetail(_ series: XtreamSeries, forceRefresh: Bool = false) async throws -> XtreamSeriesDetail {
        try await load(action: "get_series_info", extra: [("series_id", series.id)], maxAge: 6 * 3600, force: forceRefresh) { json in
            guard let root = json as? [String: Any] else { throw PlaylistError.badResponse }
            let info = root["info"] as? [String: Any] ?? [:]

            // « episodes » est un objet { "1": [...] } ou un tableau de saisons selon les serveurs.
            var raw: [(season: Int?, record: [String: Any])] = []
            if let bySeason = root["episodes"] as? [String: Any] {
                for (key, value) in bySeason {
                    raw += records(value).map { (Int(key), $0) }
                }
            } else if let list = root["episodes"] as? [Any] {
                for value in list {
                    raw += records(value).map { (nil, $0) }
                }
            }

            var seasons: [Int: [XtreamEpisode]] = [:]
            for (key, record) in raw {
                guard let id = text(record["id"]) else { continue }
                let season = int(record["season"]) ?? key ?? 1
                let number = int(record["episode_num"])
                let details = record["info"] as? [String: Any] ?? [:]
                let title = text(record["title"]) ?? "Épisode \(number.map(String.init) ?? id)"
                let channel = Channel(
                    id: UUID(stableFrom: "\(server.absoluteString)|episode|\(id)"),
                    name: title,
                    url: streamURL("series", id: id, extension: text(record["container_extension"]) ?? "mp4"),
                    logoURL: text(details["movie_image"]).flatMap(URL.init(string:)) ?? series.coverURL,
                    group: series.name
                )
                seasons[season, default: []].append(
                    XtreamEpisode(number: number, title: title, duration: text(details["duration"]), channel: channel)
                )
            }

            return XtreamSeriesDetail(
                plot: text(info["plot"]) ?? series.plot,
                cast: text(info["cast"]),
                genre: text(info["genre"]) ?? series.genre,
                releaseDate: text(info["releaseDate"]) ?? series.releaseDate,
                coverURL: text(info["cover"]).flatMap(URL.init(string:)) ?? series.coverURL,
                seasons: seasons.keys.sorted().map { number in
                    XtreamSeason(number: number, episodes: seasons[number]!.sorted { ($0.number ?? 0) < ($1.number ?? 0) })
                }
            )
        }
    }

    /// Émission en cours et suivantes d'une chaîne en direct, triées, sans celles déjà terminées.
    public func guide(for channel: Channel, limit: Int = 6, forceRefresh: Bool = false) async throws -> [EPGProgramme] {
        guard let streamID = channel.streamID else { return [] }
        let extra = [("stream_id", streamID), ("limit", String(limit))]
        let programmes = try await load(action: "get_short_epg", extra: extra, maxAge: 15 * 60, force: forceRefresh) { json in
            records((json as? [String: Any])?["epg_listings"] ?? []).compactMap { record -> EPGProgramme? in
                guard let start = double(record["start_timestamp"]).map(Date.init(timeIntervalSince1970:)),
                      let end = double(record["stop_timestamp"] ?? record["end_timestamp"]).map(Date.init(timeIntervalSince1970:)),
                      end > start else { return nil }
                return EPGProgramme(
                    title: decodedText(record["title"]) ?? "Programme sans titre",
                    summary: decodedText(record["description"]),
                    start: start,
                    end: end
                )
            }
        }
        let now = Date.now
        return programmes.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    public func clearCache() {
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
    }

    // MARK: Réseau et cache

    private func load<T>(
        action: String?,
        extra: [(String, String)] = [],
        maxAge: TimeInterval,
        force: Bool,
        parse: (Any) throws -> T
    ) async throws -> T {
        let file = cacheFile(action: action, extra: extra)

        if !force, let file,
           let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
           let value = try? parse(json) {
            return value
        }

        let (data, response) = try await session.data(from: endpoint(action: action, extra: extra))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlaylistError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw PlaylistError.badResponse
        }
        let value = try parse(json)

        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return value
    }

    private func endpoint(action: String?, extra: [(String, String)]) -> URL {
        var query = [("username", username), ("password", password)]
        if let action { query.append(("action", action)) }
        query += extra
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path += "/player_api.php"
        components.percentEncodedQuery = query.map { "\($0)=\(Xtream.encode($1))" }.joined(separator: "&")
        return components.url!
    }

    private func cacheFile(action: String?, extra: [(String, String)]) -> URL? {
        let name = ([action ?? "account"] + extra.map { "\($0)-\($1)" }).joined(separator: "_")
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "-", options: .regularExpression)
        return cacheDirectory?.appending(path: "\(name).json")
    }

    private func streamURL(_ kind: String, id: String, extension ext: String) -> URL {
        server.appending(path: kind).appending(path: username).appending(path: password).appending(path: "\(id).\(ext)")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Lecture tolérante du JSON (nombres en texte, champs nuls, objets vides…)

private func records(_ json: Any) -> [[String: Any]] {
    if let list = json as? [[String: Any]] { return list }
    if let list = json as? [Any] { return list.compactMap { $0 as? [String: Any] } }
    if let object = json as? [String: Any] { return object.values.compactMap { $0 as? [String: Any] } }
    return []
}

private func text(_ value: Any?) -> String? {
    switch value {
    case let string as String: string.nilIfBlank
    case let number as NSNumber: number.stringValue
    default: nil
    }
}

/// Les panneaux Xtream encodent titres et descriptions du guide en base64 (la plupart du temps).
private func decodedText(_ value: Any?) -> String? {
    guard let raw = text(value) else { return nil }
    if raw.count % 4 == 0,
       let data = Data(base64Encoded: raw),
       let decoded = String(data: data, encoding: .utf8),
       !decoded.contains("\u{FFFD}"),
       decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) {
        return decoded.nilIfBlank
    }
    return raw
}

private func int(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber: number.intValue
    case let string as String: Int(string.trimmingCharacters(in: .whitespaces))
    default: nil
    }
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: number.doubleValue
    case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
    default: nil
    }
}

extension UUID {
    /// Même entrée, même identifiant : la sélection survit au rechargement d'une liste.
    init(stableFrom key: String) {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
