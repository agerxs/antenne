import Foundation

/// Journal de la synchronisation iCloud dans Application Support (`sync-log.txt`), pour comprendre
/// ce qui part et ce qui arrive. Il ne contient que des nombres et des raisons, jamais de données.
enum SyncLog {
    private static let file = URL.applicationSupportDirectory.appending(path: "Antenne/sync-log.txt")
    private static let limit = 200

    static func write(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(message)"
        let previous = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").suffix(limit - 1) ?? []
        try? (previous + [Substring(line)]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func describe(_ notification: Notification) -> String {
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        let label = switch reason {
        case NSUbiquitousKeyValueStoreServerChange: "autre appareil"
        case NSUbiquitousKeyValueStoreInitialSyncChange: "première synchronisation"
        case NSUbiquitousKeyValueStoreQuotaViolationChange: "quota dépassé"
        case NSUbiquitousKeyValueStoreAccountChange: "changement de compte iCloud"
        default: "raison inconnue"
        }
        return "\(label), clés : \(keys.sorted().joined(separator: ", "))"
    }
}
