import Foundation

/// Lit les playlists M3U / M3U8 « étendues » utilisées par les fournisseurs IPTV.
public enum M3UParser {
    public static func parse(_ content: String) -> [Channel] {
        var channels: [Channel] = []
        var pending = PendingEntry()

        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if let body = value(after: "#EXTINF:", in: line) {
                    pending.apply(extinf: body)
                } else if let group = value(after: "#EXTGRP:", in: line), pending.group == nil {
                    pending.group = group.nilIfBlank
                } else if let option = value(after: "#EXTVLCOPT:", in: line),
                          let agent = value(after: "http-user-agent=", in: option) {
                    pending.userAgent = agent.nilIfBlank
                }
                continue
            }

            if let url = streamURL(from: line) {
                channels.append(pending.channel(url: url))
            }
            pending = PendingEntry()
        }
        return channels
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private static func streamURL(from line: String) -> URL? {
        let url = URL(string: line)
            ?? line.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url, url.scheme != nil, url.host() != nil else { return nil }
        return url
    }
}

private struct PendingEntry {
    var title: String?
    var attributes: [String: String] = [:]
    var group: String?
    var userAgent: String?

    private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#)

    mutating func apply(extinf body: String) {
        // Le titre suit la première virgule hors guillemets : les attributs peuvent en contenir.
        var inQuotes = false
        var commaIndex: String.Index?
        for index in body.indices {
            switch body[index] {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes: commaIndex = index
            default: break
            }
            if commaIndex != nil { break }
        }

        let head = commaIndex.map { String(body[..<$0]) } ?? body
        if let commaIndex {
            title = body[body.index(after: commaIndex)...].trimmingCharacters(in: .whitespaces).nilIfBlank
        }

        let range = NSRange(head.startIndex..., in: head)
        for match in Self.attributePattern.matches(in: head, range: range) {
            guard let key = Range(match.range(at: 1), in: head),
                  let value = Range(match.range(at: 2), in: head) else { continue }
            attributes[head[key].lowercased()] = String(head[value])
        }
    }

    func channel(url: URL) -> Channel {
        let name = title
            ?? attributes["tvg-name"]?.nilIfBlank
            ?? url.deletingPathExtension().lastPathComponent.nilIfBlank
            ?? "Chaîne sans nom"
        return Channel(
            name: name,
            url: url,
            logoURL: attributes["tvg-logo"]?.nilIfBlank.flatMap(URL.init(string:)),
            group: attributes["group-title"]?.nilIfBlank ?? group,
            tvgID: attributes["tvg-id"]?.nilIfBlank,
            userAgent: userAgent
        )
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
