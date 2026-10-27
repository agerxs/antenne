import Foundation

/// Abonnements « Xtream Codes » : un serveur, un identifiant et un mot de passe,
/// d'où le fournisseur génère la playlist M3U.
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

    /// Playlist complète (attributs tvg) avec des flux HLS, seuls lisibles par le lecteur d'Apple.
    public static func playlistURL(server: URL, username: String, password: String) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        components.path += "/get.php"
        components.percentEncodedQuery = [
            ("username", username),
            ("password", password),
            ("type", "m3u_plus"),
            ("output", "m3u8"),
        ]
        .map { "\($0)=\(encode($1))" }
        .joined(separator: "&")
        return components.url
    }

    private static func encode(_ value: String) -> String {
        // « + » serait lu comme une espace par la plupart des serveurs.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
