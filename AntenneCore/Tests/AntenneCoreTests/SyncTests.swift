import Foundation
import Testing
@testable import AntenneCore

/// iCloud en mémoire, partagé par deux « appareils » d'un même test.
final class FakeCloud: CloudKeyValueStore {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { true }
}

private let m3u = """
#EXTM3U
#EXTINF:-1,Une
https://a.example/1.m3u8
"""

@MainActor
@Suite(.serialized)
struct SyncTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "antenne-sync-\(UUID().uuidString)")
    let cloud = FakeCloud()
    let credentials = MemoryCredentials()

    private func device(_ name: String) -> PlaylistStore {
        PlaylistStore(
            directory: root.appending(path: name),
            session: StubProtocol.session,
            credentials: credentials,
            cacheDirectory: root.appending(path: "\(name)-cache"),
            cloud: cloud
        )
    }

    private func channel(_ path: String) -> Channel {
        Channel(name: path, url: URL(string: "http://vod.example/movie/u/p/\(path)")!)
    }

    @Test func playlistAddedOnOneDeviceAppearsOnTheOther() async throws {
        let url = URL(string: "https://sync.example/liste.m3u")!
        StubProtocol.responses[url] = (200, m3u)
        let mac = device("mac")
        let iphone = device("iphone")

        let playlist = try await mac.addRemote(name: "Salon", url: url)
        iphone.pullFromCloud()

        #expect(iphone.playlists.map(\.name) == ["Salon"])
        // Ses chaînes se téléchargent sur le nouvel appareil.
        for _ in 0..<50 where iphone.channels(in: playlist.id).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(iphone.channels(in: playlist.id).map(\.name) == ["Une"])
    }

    @Test func renameAndDeleteTravelBothWays() async throws {
        let url = URL(string: "https://sync.example/renomme.m3u")!
        StubProtocol.responses[url] = (200, m3u)
        let mac = device("mac")
        let iphone = device("iphone")
        let playlist = try await mac.addRemote(name: "Avant", url: url)
        iphone.pullFromCloud()

        iphone.rename(playlist.id, to: "Après")
        mac.pullFromCloud()
        #expect(mac.playlists.map(\.name) == ["Après"])

        mac.delete(playlist.id)
        iphone.pullFromCloud()
        #expect(iphone.playlists.isEmpty)

        // La trace de suppression empêche l'iPhone de la recréer chez le Mac.
        mac.pullFromCloud()
        #expect(mac.playlists.isEmpty)
    }

    @Test func importedFilesStayOnTheirDevice() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "local.m3u")
        try m3u.write(to: file, atomically: true, encoding: .utf8)
        let mac = device("mac")
        let iphone = device("iphone")

        _ = try await mac.addFile(name: "Fichier", contentsOf: file)
        iphone.pullFromCloud()
        #expect(mac.playlists.map(\.name) == ["Fichier"])
        #expect(iphone.playlists.isEmpty)
    }

    @Test func accountTravelsWithoutItsPassword() async throws {
        let server = try #require(Xtream.serverURL(from: "sync-compte.example"))
        StubProtocol.responses[URL(string: "http://sync-compte.example/player_api.php?username=u&password=p")!] =
            (200, #"{"user_info":{"auth":1,"status":"Active"}}"#)
        let isolatedCredentials = MemoryCredentials()
        let mac = device("mac")
        let iphone = PlaylistStore(
            directory: root.appending(path: "iphone"), session: StubProtocol.session,
            credentials: isolatedCredentials, cacheDirectory: root.appending(path: "iphone-cache"), cloud: cloud
        )

        let account = try await mac.addXtream(name: "Abonnement", server: server, username: "u", password: "p")
        iphone.pullFromCloud()
        #expect(iphone.playlists.map(\.name) == ["Abonnement"])

        let synced = try String(data: #require(cloud.data(forKey: "playlists")), encoding: .utf8) ?? ""
        #expect(!synced.contains("\"p\""))

        // Sans trousseau iCloud, l'iPhone demande le mot de passe une fois.
        #expect(!iphone.hasPassword(for: account.id))
        #expect(iphone.xtreamClient(for: account.id) == nil)
        try iphone.setPassword("p", for: account.id)
        #expect(iphone.xtreamClient(for: account.id)?.username == "u")
    }

    @Test func favoritesMergeAndLatestChoiceWins() {
        let mac = device("mac")
        let iphone = device("iphone")
        let film = channel("1.mp4")
        let serie = channel("2.mkv")

        mac.toggleFavorite(film)
        iphone.pullFromCloud()
        iphone.toggleFavorite(serie)
        mac.pullFromCloud()
        #expect(Set(mac.favorites.map(\.name)) == ["1.mp4", "2.mkv"])

        iphone.toggleFavorite(film)
        mac.pullFromCloud()
        #expect(mac.favorites.map(\.name) == ["2.mkv"])
    }

    @Test func progressFollowsTheViewerAcrossDevices() {
        let mac = device("mac")
        let iphone = device("iphone")
        let film = channel("3.mp4")

        mac.recordProgress(film, position: 1_200, duration: 5_400)
        iphone.pullFromCloud()
        #expect(iphone.progress(for: film)?.resumePosition == 1_200)

        iphone.recordProgress(film, position: 2_000, duration: 5_400)
        mac.pullFromCloud()
        #expect(mac.progress(for: film)?.position == 2_000)
    }

    @Test func legacyFilesAreMigratedInOrder() throws {
        let directory = root.appending(path: "ancien")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = Playlist(name: "Zèbre", source: .remote(URL(string: "https://a.example/z")!), channelCount: 3, addedAt: nil)
        let second = Playlist(name: "Abeille", source: .remote(URL(string: "https://a.example/a")!), channelCount: 1, addedAt: nil)
        try JSONEncoder().encode([first, second]).write(to: directory.appending(path: "playlists.json"))
        try JSONEncoder().encode([channel("4.mp4"), channel("5.mp4")]).write(to: directory.appending(path: "favorites.json"))

        let store = PlaylistStore(directory: directory, credentials: credentials, cacheDirectory: root.appending(path: "c"))
        #expect(store.playlists.map(\.name) == ["Zèbre", "Abeille"])
        #expect(store.favorites.map(\.name) == ["4.mp4", "5.mp4"])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "playlists.json").path))

        let relaunched = PlaylistStore(directory: directory, credentials: credentials, cacheDirectory: root.appending(path: "c"))
        #expect(relaunched.playlists.map(\.name) == ["Zèbre", "Abeille"])
    }

    @Test func samePlaylistAddedOnBothDevicesIsKeptOnce() async throws {
        let url = URL(string: "https://sync.example/double.m3u")!
        StubProtocol.responses[url] = (200, m3u)
        let iphoneCloud = FakeCloud()
        // Deux appareils qui ne se voient pas encore : chacun ajoute la même playlist.
        let mac = device("mac")
        let iphone = PlaylistStore(
            directory: root.appending(path: "iphone"), session: StubProtocol.session,
            credentials: credentials, cacheDirectory: root.appending(path: "iphone-cache"), cloud: iphoneCloud
        )
        let first = try await mac.addRemote(name: "Sur le Mac", url: url)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await iphone.addRemote(name: "Sur l'iPhone", url: url)

        // Puis l'iPhone rejoint le même iCloud que le Mac.
        let reconnected = PlaylistStore(
            directory: root.appending(path: "iphone"), session: StubProtocol.session,
            credentials: credentials, cacheDirectory: root.appending(path: "iphone-cache"), cloud: cloud
        )
        mac.pullFromCloud()

        #expect(reconnected.playlists.map(\.id) == [first.id])
        #expect(mac.playlists.map(\.id) == [first.id])
    }

    @Test func duplicateAccountKeepsAPasswordKnownOnlyLocally() async throws {
        let server = try #require(Xtream.serverURL(from: "double-compte.example"))
        StubProtocol.responses[URL(string: "http://double-compte.example/player_api.php?username=u&password=p")!] =
            (200, #"{"user_info":{"auth":1,"status":"Active"}}"#)
        let macCredentials = MemoryCredentials()
        let iphoneCredentials = MemoryCredentials()
        let macCloud = FakeCloud()
        let mac = PlaylistStore(directory: root.appending(path: "mac"), session: StubProtocol.session,
                                credentials: macCredentials, cacheDirectory: root.appending(path: "m"), cloud: macCloud)
        let iphone = PlaylistStore(directory: root.appending(path: "iphone"), session: StubProtocol.session,
                                   credentials: iphoneCredentials, cacheDirectory: root.appending(path: "i"), cloud: cloud)
        let older = try await mac.addXtream(name: "Compte", server: server, username: "u", password: "p")
        try await Task.sleep(for: .milliseconds(5))
        let newer = try await iphone.addXtream(name: "Compte", server: server, username: "u", password: "p")

        // L'iPhone découvre l'exemplaire du Mac, plus ancien, sans trousseau iCloud pour son mot de passe.
        cloud.values["playlists"] = macCloud.values["playlists"].map { mergedPlaylists($0, cloud.values["playlists"]) }
        iphone.pullFromCloud()

        #expect(iphone.playlists.map(\.id) == [older.id])
        #expect(iphoneCredentials.password(for: older.id) == "p")
        #expect(iphone.xtreamClient(for: older.id) != nil)
        #expect(iphone.xtreamClient(for: newer.id) == nil)
    }

    private func mergedPlaylists(_ a: Any, _ b: Any?) -> Data {
        let decoder = JSONDecoder()
        var first = (try? decoder.decode([String: Library.Entry<Playlist>].self, from: a as! Data)) ?? [:]
        let second = (b as? Data).flatMap { try? decoder.decode([String: Library.Entry<Playlist>].self, from: $0) } ?? [:]
        first.merge(second) { current, _ in current }
        return try! JSONEncoder().encode(first)
    }

    @Test func refreshOnOneDeviceDoesNotUndoARenameElsewhere() async throws {
        let url = URL(string: "https://sync.example/actualise.m3u")!
        StubProtocol.responses[url] = (200, m3u)
        let mac = device("mac")
        let iphone = device("iphone")
        let playlist = try await mac.addRemote(name: "Avant", url: url)
        iphone.pullFromCloud()

        iphone.rename(playlist.id, to: "Renommée")
        try await mac.refresh(playlist.id)
        mac.pullFromCloud()
        #expect(mac.playlists.first?.name == "Renommée")
        #expect(mac.playlists.first?.channelCount == 1)
    }
}

struct PlaybackProgressTests {
    @Test func resumeOnlyWhenItIsWorthIt() {
        #expect(PlaybackProgress(position: 12, duration: 3_600).resumePosition == nil)
        #expect(PlaybackProgress(position: 600, duration: 3_600).resumePosition == 600)
        #expect(PlaybackProgress(position: 3_500, duration: 3_600).resumePosition == nil)
        #expect(PlaybackProgress(position: 3_500, duration: 3_600).isFinished)
    }

    @Test @MainActor func liveAndShortClipsAreNotTracked() {
        let root = FileManager.default.temporaryDirectory.appending(path: "antenne-progress-\(UUID().uuidString)")
        let store = PlaylistStore(directory: root, credentials: MemoryCredentials(), cacheDirectory: root.appending(path: "c"))
        let live = Channel(name: "Direct", url: URL(string: "http://a.example/live/u/p/1.m3u8")!)
        let clip = Channel(name: "Clip", url: URL(string: "http://a.example/clip.mp4")!)
        let film = Channel(name: "Film", url: URL(string: "http://a.example/movie/u/p/9.mp4")!)

        store.recordProgress(live, position: 300, duration: .infinity)
        store.recordProgress(clip, position: 40, duration: 45)
        store.recordProgress(film, position: 4, duration: 5_000)
        #expect(store.progress(for: live) == nil)
        #expect(store.progress(for: clip) == nil)
        #expect(store.progress(for: film) == nil)

        store.recordProgress(film, position: 45, duration: 5_000)
        #expect(store.progress(for: film)?.position == 45)
    }

    @Test func oldestProgressIsPrunedFirst() {
        var library = Library()
        for index in 0..<5 {
            library.progress["\(index)"] = .init(value: PlaybackProgress(position: 100, duration: 1_000),
                                                 modifiedAt: Date(timeIntervalSince1970: Double(index)))
        }
        library.pruneProgress(keeping: 2)
        #expect(Set(library.progress.keys) == ["3", "4"])
    }
}
