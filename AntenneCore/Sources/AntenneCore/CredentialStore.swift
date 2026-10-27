import Foundation
import Security

/// Mots de passe des comptes, rangés à part des playlists.
public protocol CredentialStore: Sendable {
    func password(for id: Playlist.ID) -> String?
    func setPassword(_ password: String, for id: Playlist.ID) throws
    func removePassword(for id: Playlist.ID)
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "ci.novae.antenne.account") {
        self.service = service
    }

    public func password(for id: Playlist.ID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for id: Playlist.ID) throws {
        removePassword(for: id)
        var query = baseQuery(id)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PlaylistError.keychain(status) }
    }

    public func removePassword(for id: Playlist.ID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }

    private func baseQuery(_ id: Playlist.ID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
