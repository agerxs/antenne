import Foundation

public enum StreamURL {
    /// Adresses à essayer dans l'ordre. Le lecteur d'Apple ne lit pas le MPEG-TS brut,
    /// alors que les serveurs Xtream servent presque toujours la même chaîne en HLS (.m3u8).
    public static func candidates(for url: URL) -> [URL] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [url] }

        let ext = url.pathExtension.lowercased()
        guard ext == "ts" || ext.isEmpty else { return [url] }

        let base = ext.isEmpty ? url : url.deletingPathExtension()
        var result = [url, base.appendingPathExtension("m3u8")]

        // Xtream : http://hôte/utilisateur/motdepasse/id → http://hôte/live/utilisateur/motdepasse/id.m3u8
        let parts = base.pathComponents.filter { $0 != "/" }
        if parts.count == 3, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.path = "/live/" + parts.joined(separator: "/") + ".m3u8"
            if let live = components.url { result.append(live) }
        }
        return result
    }
}
