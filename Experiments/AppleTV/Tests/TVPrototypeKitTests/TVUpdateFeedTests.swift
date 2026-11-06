import Foundation
import Testing
@testable import TVPrototypeKit

struct TVUpdateFeedTests {
    private func github(_ tag: String = "tvos-v0.1.1-b2", asset: String = "MijiaLAN-tvOS-0.1.1-b2.ipa", draft: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [["tag_name": tag, "draft": draft,
            "published_at": "2026-11-06T00:00:00Z", "body": "TV release notes",
            "assets": [["name": asset, "size": 123]]]])
    }

    @Test func onlyPublishedTVArtifactsAreAnnounced() throws {
        let feed = try TVUpdateFeed.fromGitHub(github())
        #expect(feed.newest(after: 1)?.version == "0.1.1")
        #expect(feed.newest(after: 2) == nil)
        for data in [github("v0.1.1"), github("rs-v0.1.1-b2"), github(asset: "MijiaLAN-0.1.1-universal.zip"), github(draft: true)] {
            #expect(try TVUpdateFeed.fromGitHub(data).releases.isEmpty)
        }
    }

    @Test func numericBuildsDoNotCompareAsTextAndNeverDowngrade() throws {
        let feed = try TVUpdateFeed(releases: [
            .init(version: "0.1.0", build: 2, notes: "", publishedAt: "2026-11-06T00:00:00Z"),
            .init(version: "0.1.0", build: 10, notes: "", publishedAt: "2026-11-06T00:00:00Z")
        ]).validated()
        #expect(feed.newest(after: 1)?.build == 10)
        #expect(feed.newest(after: 10) == nil)
    }

    @Test func wrongPlatformIdentityForeignLinksAndAmbiguousBuildsFail() throws {
        let valid = try TVUpdateFeed.fromGitHub(github())
        var wrong = valid; wrong.platform = "macOS"
        #expect(throws: TVUpdateError.self) { try wrong.validated() }
        wrong = valid; wrong.bundleIdentifier = "com.mijialan.MijiaLAN"
        #expect(throws: TVUpdateError.self) { try wrong.validated() }
        wrong = valid; wrong.channel = "appStore"
        #expect(throws: TVUpdateError.self) { try wrong.validated() }
        wrong = valid; wrong.releases[0].releaseURL = URL(string: "https://example.com/download")!
        #expect(throws: TVUpdateError.self) { try wrong.validated() }
        wrong = valid; wrong.releases += valid.releases
        #expect(throws: TVUpdateError.self) { try wrong.validated() }
    }

    @Test func missingOrMalformedJSONDoesNotBecomeAnEmptySuccessfulFeed() throws {
        #expect(throws: (any Error).self) { try TVUpdateFeed.decode(Data("<html>404</html>".utf8)) }
        #expect(throws: (any Error).self) { try TVUpdateFeed.decode(Data("{}".utf8)) }
        let empty = try TVUpdateFeed.decode(JSONEncoder().encode(TVUpdateFeed(releases: [])))
        #expect(empty.releases.isEmpty)
    }
}
