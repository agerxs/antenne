import Foundation
import Testing
@testable import AntenneCore

private let sample = """
#EXTM3U
#EXTINF:-1 group-title="Infos",France 24
https://a.example/f24.m3u8
#EXTINF:-1 group-title="Sport",Sport 1
https://a.example/sport1.m3u8
"""

@MainActor
@Suite(.serialized)
struct PlaylistStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "antenne-tests-\(UUID().uuidString)")
    let credentials = MemoryCredentials()

    private func writeFile(_ content: String, named name: String = "liste.m3u") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importedFilePersistsAcrossLaunches() async throws {
        let store = PlaylistStore(directory: directory, credentials: credentials)
        let playlist = try await store.addFile(name: "Maison", contentsOf: writeFile(sample))
        #expect(playlist.channelCount == 2)
        #expect(playlist.source == .file(name: "liste.m3u"))

        let relaunched = PlaylistStore(directory: directory, credentials: credentials)
        #expect(relaunched.playlists.map(\.name) == ["Maison"])
        #expect(relaunched.channels(in: playlist.id).map(\.name) == ["France 24", "Sport 1"])
    }

    @Test func fileWithoutChannelIsRejected() async throws {
        let store = PlaylistStore(directory: directory, credentials: credentials)
        await #expect(throws: PlaylistError.empty) {
            try await store.addFile(name: "Vide", contentsOf: try writeFile("#EXTM3U\n"))
        }
        #expect(store.playlists.isEmpty)
    }

    @Test func favoritesPersistAndToggle() async throws {
        let store = PlaylistStore(directory: directory, credentials: credentials)
        let playlist = try await store.addFile(name: "Maison", contentsOf: writeFile(sample))
        let channel = try #require(store.channels(in: playlist.id).first)

        store.toggleFavorite(channel)
        #expect(PlaylistStore(directory: directory, credentials: credentials).favorites.map(\.name) == ["France 24"])

        store.toggleFavorite(channel)
        #expect(PlaylistStore(directory: directory, credentials: credentials).favorites.isEmpty)
    }

    @Test func renameAndDelete() async throws {
        let store = PlaylistStore(directory: directory, credentials: credentials)
        let playlist = try await store.addFile(name: "Maison", contentsOf: writeFile(sample))

        store.rename(playlist.id, to: "  Salon  ")
        store.rename(playlist.id, to: "   ")
        #expect(PlaylistStore(directory: directory, credentials: credentials).playlists.first?.name == "Salon")

        store.delete(playlist.id)
        let relaunched = PlaylistStore(directory: directory, credentials: credentials)
        #expect(relaunched.playlists.isEmpty)
        #expect(relaunched.channels(in: playlist.id).isEmpty)
    }

    @Test func remotePlaylistDownloadsAndRefreshes() async throws {
        let url = URL(string: "https://provider.example/get.php?type=m3u")!
        StubProtocol.responses[url] = (200, sample)
        let store = PlaylistStore(directory: directory, session: StubProtocol.session, credentials: credentials)

        let playlist = try await store.addRemote(name: "Abonnement", url: url)
        #expect(playlist.channelCount == 2)

        StubProtocol.responses[url] = (200, sample + "\n#EXTINF:-1,Nouvelle\nhttps://a.example/new.m3u8")
        try await store.refresh(playlist.id)
        #expect(store.playlists.first?.channelCount == 3)
        #expect(store.channels(in: playlist.id).last?.name == "Nouvelle")
    }

    @Test func xtreamAccountIsValidatedWithoutDownloadingThePlaylist() async throws {
        let server = try #require(Xtream.serverURL(from: "store.example.tv:8080"))
        let api = "http://store.example.tv:8080/player_api.php?username=ager&password=s3cr%2Bt"
        StubProtocol.responses[URL(string: api)!] = (200, #"{"user_info":{"auth":1,"status":"Active"}}"#)
        let store = makeStore()

        let playlist = try await store.addXtream(name: "Abonnement", server: server, username: "ager", password: "s3cr+t")
        #expect(playlist.source == .xtream(server: server, username: "ager"))
        #expect(credentials.password(for: playlist.id) == "s3cr+t")
        #expect(store.xtreamClient(for: playlist.id)?.username == "ager")

        let saved = try String(contentsOf: directory.appending(path: "playlists.json"), encoding: .utf8)
        #expect(!saved.contains("s3cr"))

        store.delete(playlist.id)
        #expect(credentials.password(for: playlist.id) == nil)
    }

    @Test func xtreamRefusedOrExpiredAccountIsNotAdded() async throws {
        let server = try #require(Xtream.serverURL(from: "refus.example.tv"))
        StubProtocol.responses[URL(string: "http://refus.example.tv/player_api.php?username=u&password=faux")!] =
            (200, #"{"user_info":{"auth":0}}"#)
        StubProtocol.responses[URL(string: "http://refus.example.tv/player_api.php?username=u&password=vieux")!] =
            (200, #"{"user_info":{"auth":"1","status":"Expired"}}"#)
        let store = makeStore()

        await #expect(throws: PlaylistError.invalidCredentials) {
            try await store.addXtream(name: "A", server: server, username: "u", password: "faux")
        }
        await #expect(throws: PlaylistError.accountInactive("Expired")) {
            try await store.addXtream(name: "A", server: server, username: "u", password: "vieux")
        }
        #expect(store.playlists.isEmpty)
    }

    @Test func xtreamRefreshNeedsThePassword() async throws {
        let server = try #require(Xtream.serverURL(from: "http://mdp.example.tv"))
        StubProtocol.responses[URL(string: "http://mdp.example.tv/player_api.php?username=u&password=p")!] =
            (200, #"{"user_info":{"auth":1,"status":"Active"}}"#)
        let store = makeStore()
        let playlist = try await store.addXtream(name: "A", server: server, username: "u", password: "p")

        try await store.refresh(playlist.id)
        credentials.removePassword(for: playlist.id)
        #expect(store.xtreamClient(for: playlist.id) == nil)
        await #expect(throws: PlaylistError.missingPassword) {
            try await store.refresh(playlist.id)
        }
    }

    @Test func oldFullPlaylistCopyOfAnAccountIsDeletedAtLaunch() throws {
        let server = try #require(Xtream.serverURL(from: "old.example.tv"))
        let playlist = Playlist(name: "Ancien", source: .xtream(server: server, username: "u"), channelCount: 591_542)
        let channels = directory.appending(path: "channels")
        try FileManager.default.createDirectory(at: channels, withIntermediateDirectories: true)
        try JSONEncoder().encode([playlist]).write(to: directory.appending(path: "playlists.json"))
        let oldCopy = channels.appending(path: "\(playlist.id.uuidString).json")
        try Data("[]".utf8).write(to: oldCopy)

        _ = makeStore()
        #expect(!FileManager.default.fileExists(atPath: oldCopy.path))
    }

    private func makeStore() -> PlaylistStore {
        PlaylistStore(
            directory: directory,
            session: StubProtocol.session,
            credentials: credentials,
            cacheDirectory: directory.appending(path: "cache")
        )
    }

    @Test func remoteHTTPErrorIsReported() async throws {
        let url = URL(string: "https://provider.example/expired.m3u")!
        StubProtocol.responses[url] = (403, "Forbidden")
        let store = PlaylistStore(directory: directory, session: StubProtocol.session, credentials: credentials)

        await #expect(throws: PlaylistError.http(403)) {
            try await store.addRemote(name: "Expiré", url: url)
        }
    }
}

final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: [URL: (Int, String)] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]

    static var responses: Responses { Responses() }

    struct Responses {
        subscript(url: URL) -> (Int, String)? {
            get { StubProtocol.lock.withLock { StubProtocol.stored[url] } }
            nonmutating set { StubProtocol.lock.withLock { StubProtocol.stored[url] = newValue } }
        }
    }

    static func requestCount(_ url: URL) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.lock.withLock {
            Self.counts[url, default: 0] += 1
            return Self.stored[url]
        }
        guard let (status, body) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private var passwords: [Playlist.ID: String] = [:]

    func password(for id: Playlist.ID) -> String? { passwords[id] }
    func setPassword(_ password: String, for id: Playlist.ID) throws { passwords[id] = password }
    func removePassword(for id: Playlist.ID) { passwords[id] = nil }
}
