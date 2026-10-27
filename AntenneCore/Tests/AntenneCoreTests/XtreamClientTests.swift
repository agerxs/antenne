import Foundation
import Testing
@testable import AntenneCore

@Suite(.serialized)
struct XtreamClientTests {
    let cache = FileManager.default.temporaryDirectory.appending(path: "antenne-xtream-\(UUID().uuidString)")

    /// Chaque test a son serveur : les réponses du stub sont partagées entre suites.
    private func client(_ host: String, password: String = "p+w") -> XtreamClient {
        XtreamClient(
            server: URL(string: "http://\(host):8080")!,
            username: "ager",
            password: password,
            session: StubProtocol.session,
            cacheDirectory: cache
        )
    }

    private func stub(_ host: String, _ query: String, _ body: String, status: Int = 200) -> URL {
        let url = URL(string: "http://\(host):8080/player_api.php?username=ager&password=p%2Bw\(query)")!
        StubProtocol.responses[url] = (status, body)
        return url
    }

    @Test func serverInputIsNormalized() {
        #expect(Xtream.serverURL(from: " line.example.tv:8080 ")?.absoluteString == "http://line.example.tv:8080")
        #expect(Xtream.serverURL(from: "https://line.example.tv/")?.absoluteString == "https://line.example.tv")
        #expect(Xtream.serverURL(from: "http://line.example.tv/panel/?x=1")?.absoluteString == "http://line.example.tv/panel")
        #expect(Xtream.serverURL(from: "ftp://line.example.tv") == nil)
        #expect(Xtream.serverURL(from: "") == nil)
    }

    @Test func accountInfoAcceptsNumbersWrittenAsText() async throws {
        _ = stub("compte.tv", "", #"""
        {"user_info":{"auth":1,"status":"Active","exp_date":"1793136060","is_trial":"1",
          "active_cons":"0","max_connections":"1"},"server_info":{}}
        """#)
        let info = try await client("compte.tv").accountInfo()
        #expect(info.isActive)
        #expect(info.isTrial)
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_793_136_060))
        #expect(info.activeConnections == 0)
        #expect(info.maxConnections == 1)
    }

    @Test func refusedCredentialsAndGarbageAreReported() async throws {
        _ = stub("refus.tv", "", #"{"user_info":{"auth":0}}"#)
        _ = stub("html.tv", "", "<html>Bienvenue</html>")
        await #expect(throws: PlaylistError.invalidCredentials) { try await client("refus.tv").accountInfo() }
        await #expect(throws: PlaylistError.badResponse) { try await client("html.tv").accountInfo() }
    }

    @Test func liveCategoryGivesPlayableHLSChannels() async throws {
        _ = stub("live.tv", "&action=get_live_categories", #"""
        [{"category_id":"12","category_name":"FR| SPORTS","parent_id":0},{"category_id":13,"category_name":"CI| INFOS"}]
        """#)
        _ = stub("live.tv", "&action=get_live_streams&category_id=12", #"""
        [{"num":1,"name":"beIN 1","stream_type":"live","stream_id":101,"stream_icon":"http://img.tv/bein.png",
          "epg_channel_id":"bein1.fr","category_id":"12"},
         {"num":2,"name":"Sans icône","stream_id":"102","stream_icon":"","epg_channel_id":null}]
        """#)
        let client = client("live.tv")

        let categories = try await client.categories(.live)
        #expect(categories.map(\.id) == ["12", "13"])
        #expect(categories.map(\.name) == ["FR| SPORTS", "CI| INFOS"])

        let channels = try await client.channels(.live, in: categories[0])
        #expect(channels.map(\.name) == ["beIN 1", "Sans icône"])
        #expect(channels[0].url.absoluteString == "http://live.tv:8080/live/ager/p+w/101.m3u8")
        #expect(channels[0].logoURL?.absoluteString == "http://img.tv/bein.png")
        #expect(channels[0].group == "FR| SPORTS")
        #expect(channels[0].tvgID == "bein1.fr")
        #expect(channels[1].logoURL == nil)

        // Identifiants stables : la sélection et les favoris survivent à un rechargement.
        #expect(try await client.channels(.live, in: categories[0], forceRefresh: true).map(\.id) == channels.map(\.id))
    }

    @Test func moviesKeepTheirContainerExtension() async throws {
        _ = stub("vod.tv", "&action=get_vod_streams&category_id=5", #"""
        [{"name":"Sissi","stream_id":7001,"stream_icon":"http://img.tv/sissi.jpg","container_extension":"mkv"},
         {"name":"Sans extension","stream_id":7002}]
        """#)
        let movies = try await client("vod.tv").channels(.movies, in: XtreamCategory(id: "5", name: "FR| FILMS"))
        #expect(movies.map { $0.url.lastPathComponent } == ["7001.mkv", "7002.mp4"])
        #expect(movies[0].url.absoluteString.contains("/movie/ager/"))
    }

    @Test func emptyCategoryAnswersAreTolerated() async throws {
        _ = stub("vide.tv", "&action=get_series_categories", "[]")
        _ = stub("vide.tv", "&action=get_vod_streams&category_id=1", "{}")
        _ = stub("vide.tv", "&action=get_live_streams&category_id=1", "null")
        let client = client("vide.tv")
        #expect(try await client.categories(.series).isEmpty)
        #expect(try await client.channels(.movies, in: XtreamCategory(id: "1", name: "A")).isEmpty)
        #expect(try await client.channels(.live, in: XtreamCategory(id: "1", name: "A")).isEmpty)
    }

    @Test func seriesDetailGroupsEpisodesBySeason() async throws {
        let show = XtreamSeries(id: "88", name: "The Americans", coverURL: URL(string: "http://img.tv/am.jpg"),
                                plot: nil, genre: nil, releaseDate: nil, rating: nil)
        _ = stub("serie.tv", "&action=get_series_info&series_id=88", #"""
        {"seasons":[],"info":{"name":"The Americans","plot":"Espions.","genre":"Drame"},
         "episodes":{"2":[{"id":"9002","episode_num":"1","title":"S02E01","container_extension":"mkv","season":2}],
                     "1":[{"id":"9013","episode_num":13,"title":"S01E13","container_extension":"mp4",
                           "info":{"duration":"00:52:10","movie_image":"http://img.tv/e13.jpg"}},
                          {"id":"9001","episode_num":1,"title":"S01E01","container_extension":"mp4"}]}}
        """#)
        let detail = try await client("serie.tv").seriesDetail(show)

        #expect(detail.plot == "Espions.")
        #expect(detail.genre == "Drame")
        #expect(detail.coverURL == show.coverURL)
        #expect(detail.seasons.map(\.number) == [1, 2])
        #expect(detail.seasons[0].episodes.map(\.title) == ["S01E01", "S01E13"])
        #expect(detail.seasons[0].episodes[1].duration == "00:52:10")
        #expect(detail.seasons[0].episodes[1].channel.logoURL?.absoluteString == "http://img.tv/e13.jpg")
        #expect(detail.seasons[0].episodes[0].channel.logoURL == show.coverURL)
        #expect(detail.seasons[1].episodes[0].channel.url.absoluteString == "http://serie.tv:8080/series/ager/p+w/9002.mkv")
    }

    @Test func seriesEpisodesMayComeAsAnArray() async throws {
        let show = XtreamSeries(id: "5", name: "Liste", coverURL: nil, plot: nil, genre: nil, releaseDate: nil, rating: nil)
        _ = stub("liste.tv", "&action=get_series_info&series_id=5", #"""
        {"info":{},"episodes":[[{"id":"1","episode_num":1,"title":"Un","season":1}],[{"id":"2","episode_num":1,"title":"Deux","season":2}]]}
        """#)
        let detail = try await client("liste.tv").seriesDetail(show)
        #expect(detail.seasons.map { $0.episodes.map(\.title) } == [["Un"], ["Deux"]])
    }

    @Test func answersAreCachedPerAccountAndRefreshable() async throws {
        let url = stub("cache.tv", "&action=get_vod_categories", #"[{"category_id":"1","category_name":"Films"}]"#)
        let client = client("cache.tv")

        _ = try await client.categories(.movies)
        _ = try await client.categories(.movies)
        #expect(StubProtocol.requestCount(url) == 1)

        _ = try await client.categories(.movies, forceRefresh: true)
        #expect(StubProtocol.requestCount(url) == 2)

        // Le mot de passe n'apparaît nulle part dans les fichiers du cache.
        let files = FileManager.default.enumerator(atPath: cache.path)?.allObjects as? [String] ?? []
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { !$0.contains("p+w") && !$0.contains("ager") })

        client.clearCache()
        _ = try await client.categories(.movies)
        #expect(StubProtocol.requestCount(url) == 3)
    }

    @Test func badAnswerIsNotCached() async throws {
        let url = stub("panne.tv", "&action=get_live_categories", "Service Unavailable", status: 503)
        let client = client("panne.tv")
        await #expect(throws: PlaylistError.http(503)) { try await client.categories(.live) }

        StubProtocol.responses[url] = (200, #"[{"category_id":"1","category_name":"Infos"}]"#)
        #expect(try await client.categories(.live).map(\.name) == ["Infos"])
    }
}
