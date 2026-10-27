import Foundation
import Security

/// Mots de passe des comptes, rangés à part des playlists.
public protocol CredentialStore: Sendable {
    func password(for id: Playlist.ID) -> String?
    func setPassword(_ password: String, for id: Playlist.ID) throws
    func removePassword(for id: Playlist.ID)
}

/// Trousseau iCloud : le mot de passe suit le compte sur les autres appareils de l'utilisateur,
/// chiffré par Apple. Sans trousseau iCloud, il reste sur l'appareil.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "ci.novae.antenne.account") {
        self.service = service
    }

    public func password(for id: Playlist.ID) -> String? {
        if let password = read(syncedQuery(id)) { return password }

        // Rangé avant la synchronisation : on le déplace dans le trousseau iCloud au passage.
        guard let legacy = read(legacyQuery(id)) else { return nil }
        if add(legacy, to: syncedQuery(id, forWriting: true)) == errSecSuccess {
            SecItemDelete(legacyQuery(id) as CFDictionary)
        }
        return legacy
    }

    public func setPassword(_ password: String, for id: Playlist.ID) throws {
        removePassword(for: id)
        var status = add(password, to: syncedQuery(id, forWriting: true))
        if status != errSecSuccess {
            // Trousseau iCloud indisponible (droits absents, par exemple) : on garde le mot de passe ici.
            status = add(password, to: legacyQuery(id))
        }
        guard status == errSecSuccess else { throw PlaylistError.keychain(status) }
    }

    public func removePassword(for id: Playlist.ID) {
        SecItemDelete(syncedQuery(id) as CFDictionary)
        SecItemDelete(legacyQuery(id) as CFDictionary)
    }

    private func read(_ query: [String: Any]) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func add(_ password: String, to query: [String: Any]) -> OSStatus {
        var query = query
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func syncedQuery(_ id: Playlist.ID, forWriting: Bool = false) -> [String: Any] {
        var query = baseQuery(id)
        query[kSecAttrSynchronizable as String] = forWriting ? kCFBooleanTrue! : kSecAttrSynchronizableAny
        #if os(macOS)
        // Sur Mac, seul le trousseau « protection des données » sait se synchroniser.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func legacyQuery(_ id: Playlist.ID) -> [String: Any] {
        baseQuery(id)
    }

    private func baseQuery(_ id: Playlist.ID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
