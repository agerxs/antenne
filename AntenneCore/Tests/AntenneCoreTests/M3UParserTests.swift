import Foundation
import Testing
@testable import AntenneCore

struct M3UParserTests {
    @Test func readsExtendedAttributes() throws {
        let channels = M3UParser.parse("""
        #EXTM3U x-tvg-url="http://epg.example/guide.xml"
        #EXTINF:-1 tvg-id="rti1.ci" tvg-name="RTI 1" tvg-logo="http://logo.example/rti1.png" group-title="Côte d'Ivoire",RTI 1 HD
        http://stream.example/live/rti1.m3u8
        """)

        let channel = try #require(channels.first)
        #expect(channels.count == 1)
        #expect(channel.name == "RTI 1 HD")
        #expect(channel.url.absoluteString == "http://stream.example/live/rti1.m3u8")
        #expect(channel.logoURL?.absoluteString == "http://logo.example/rti1.png")
        #expect(channel.group == "Côte d'Ivoire")
        #expect(channel.tvgID == "rti1.ci")
    }

    @Test func commaInsideQuotedAttributeDoesNotEndTheAttributes() throws {
        let channels = M3UParser.parse("""
        #EXTINF:-1 group-title="Sport, Football",Canal+ Sport, Afrique
        http://stream.example/1.ts
        """)
        let channel = try #require(channels.first)
        #expect(channel.group == "Sport, Football")
        #expect(channel.name == "Canal+ Sport, Afrique")
    }

    @Test func handlesCRLFBomAndBlankLines() {
        let content = "\u{FEFF}#EXTM3U\r\n\r\n#EXTINF:-1,Une\r\nhttp://a.example/1\r\n#EXTINF:-1,Deux\r\nhttp://a.example/2\r\n"
        #expect(M3UParser.parse(content).map(\.name) == ["Une", "Deux"])
    }

    @Test func readsGroupAndUserAgentDirectives() throws {
        let channels = M3UParser.parse("""
        #EXTM3U
        #EXTINF:-1,Info
        #EXTGRP:Actualités
        #EXTVLCOPT:http-user-agent=Mozilla/5.0 Antenne
        https://a.example/info.m3u8
        """)
        let channel = try #require(channels.first)
        #expect(channel.group == "Actualités")
        #expect(channel.userAgent == "Mozilla/5.0 Antenne")
    }

    @Test func groupTitleWinsOverExtgrp() throws {
        let channels = M3UParser.parse("""
        #EXTINF:-1 group-title="Films",Film
        #EXTGRP:Autre
        https://a.example/film.m3u8
        """)
        #expect(try #require(channels.first).group == "Films")
    }

    @Test func titleFallsBackToTvgNameThenURL() {
        let channels = M3UParser.parse("""
        #EXTINF:-1 tvg-name="Nommée",
        http://a.example/1.m3u8
        http://a.example/live/nue.m3u8
        """)
        #expect(channels.map(\.name) == ["Nommée", "nue"])
    }

    @Test func attributesDoNotLeakToNextChannel() {
        let channels = M3UParser.parse("""
        #EXTINF:-1 group-title="A" tvg-logo="http://l.example/a.png",A
        http://a.example/a
        #EXTINF:-1,B
        http://a.example/b
        """)
        #expect(channels[1].group == nil)
        #expect(channels[1].logoURL == nil)
    }

    @Test func ignoresUnknownDirectivesAndNonURLLines() {
        let channels = M3UParser.parse("""
        #EXTM3U
        #KODIPROP:inputstream=adaptive
        #EXTINF:-1,Cassée
        pas une url
        #EXTINF:-1,Valide
        http://a.example/ok
        """)
        #expect(channels.map(\.name) == ["Valide"])
    }

    @Test func emptyContentGivesNoChannel() {
        #expect(M3UParser.parse("").isEmpty)
        #expect(M3UParser.parse("#EXTM3U\n").isEmpty)
    }
}

struct StreamURLTests {
    @Test func hlsIsKeptAsIs() {
        let url = URL(string: "https://a.example/live/chaine.m3u8")!
        #expect(StreamURL.candidates(for: url) == [url])
    }

    @Test func transportStreamFallsBackToHLS() {
        let url = URL(string: "http://a.example/live/u/p/42.ts")!
        #expect(StreamURL.candidates(for: url).map(\.absoluteString) == [
            "http://a.example/live/u/p/42.ts",
            "http://a.example/live/u/p/42.m3u8",
        ])
    }

    @Test func xtreamShortURLAlsoTriesLivePath() {
        let url = URL(string: "http://a.example:8080/u/p/42")!
        #expect(StreamURL.candidates(for: url).map(\.absoluteString) == [
            "http://a.example:8080/u/p/42",
            "http://a.example:8080/u/p/42.m3u8",
            "http://a.example:8080/live/u/p/42.m3u8",
        ])
    }

    @Test func formatsAppleCannotReadGoStraightToVLC() {
        #expect(StreamURL.needsVLC(URL(string: "http://a.example/series/u/p/9002.mkv")!))
        #expect(StreamURL.needsVLC(URL(string: "http://a.example/movie/u/p/1.AVI")!))
        #expect(StreamURL.needsVLC(URL(string: "rtmp://a.example/live/stream")!))
        #expect(!StreamURL.needsVLC(URL(string: "http://a.example/movie/u/p/1.mp4")!))
        #expect(!StreamURL.needsVLC(URL(string: "http://a.example/live/u/p/3.m3u8")!))
        #expect(!StreamURL.needsVLC(URL(string: "http://a.example/live/u/p/3.ts")!))
    }

    @Test func nonHTTPSchemesAreUntouched() {
        let url = URL(string: "rtmp://a.example/live/stream")!
        #expect(StreamURL.candidates(for: url) == [url])
    }
}
