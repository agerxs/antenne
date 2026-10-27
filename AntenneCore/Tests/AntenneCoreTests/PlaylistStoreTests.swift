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

    @Test func xtreamAccountKeepsPasswordOutOfThePlaylistFile() async throws {
        let server = try #require(Xtream.serverURL(from: "line.example.tv:8080"))
        let expected = "http://line.example.tv:8080/get.php?username=ager&password=s3cr%2Bt&type=m3u_plus&output=m3u8"
        StubProtocol.responses[URL(string: expected)!] = (200, sample)
        let store = PlaylistStore(directory: directory, session: StubProtocol.session, credentials: credentials)

        let playlist = try await store.addXtream(name: "Abonnement", server: server, username: "ager", password: "s3cr+t")
        #expect(playlist.source == .xtream(server: server, username: "ager"))
        #expect(credentials.password(for: playlist.id) == "s3cr+t")

        let saved = try String(contentsOf: directory.appending(path: "playlists.json"), encoding: .utf8)
        #expect(!saved.contains("s3cr"))

        try await store.refresh(playlist.id)
        #expect(store.playlists.first?.channelCount == 2)

        store.delete(playlist.id)
        #expect(credentials.password(for: playlist.id) == nil)
    }

    @Test func xtreamRefreshWithoutPasswordFails() async throws {
        let server = try #require(Xtream.serverURL(from: "http://line.example.tv"))
        StubProtocol.responses[Xtream.playlistURL(server: server, username: "u", password: "p")!] = (200, sample)
        let store = PlaylistStore(directory: directory, session: StubProtocol.session, credentials: credentials)
        let playlist = try await store.addXtream(name: "A", server: server, username: "u", password: "p")

        credentials.removePassword(for: playlist.id)
        await #expect(throws: PlaylistError.missingPassword) {
            try await store.refresh(playlist.id)
        }
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
    nonisolated(unsafe) static var responses: [URL: (Int, String)] = [:]

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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
