import Foundation
import Testing

private struct FakeFetcher: HTTPFetching {
    var status = 200
    var body = ""
    var error: Error?
    func get(_ url: URL) async throws -> (Data, Int) {
        if let error { throw error }
        return (Data(body.utf8), status)
    }
}

private func release(
    tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
    page: String = "https://github.com/o/r/releases/tag/v0.2.0",
    assets: String =
        #"[{"name":"SpaceLens-0.2.0.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/SpaceLens-0.2.0.zip"},{"name":"SpaceLens-0.2.0.dmg","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/SpaceLens-0.2.0.dmg"}]"#
) -> String {
    #"{"tag_name":"\#(tag)","name":"SpaceLens 0.2.0","html_url":"\#(page)","body":"Notes","draft":\#(draft),"prerelease":\#(prerelease),"published_at":"2026-11-10T12:00:00Z","assets":\#(assets)}"#
}

@Suite struct VersionTests {
    @Test func parsesCommonShapes() {
        #expect(AppVersion("1.2.3")?.description == "1.2.3")
        #expect(AppVersion("v0.10.0")?.description == "0.10.0")
        #expect(AppVersion(" V2.0.1 ")?.description == "2.0.1")
        #expect(AppVersion("1.0.0-beta.2")?.prerelease == ["beta", "2"])
        #expect(AppVersion("1.0.0+build5")?.description == "1.0.0")
        for bad in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "-1.0.0", "1.0.0-", "1.0.0-a..b", "dev"] {
            #expect(AppVersion(bad) == nil, "\(bad) must not parse")
        }
    }

    @Test func comparesNumericallyNotAsText() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("1.2.10")! > AppVersion("1.2.9")!)
        #expect(AppVersion("1.2.3")! == AppVersion("v1.2.3")!)
    }

    @Test func prereleasesRankBelowTheirRelease() {
        #expect(AppVersion("1.0.0-rc.1")! < AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.0-alpha")! < AppVersion("1.0.0-beta")!)
        #expect(AppVersion("1.0.0-beta.2")! < AppVersion("1.0.0-beta.11")!)
        #expect(AppVersion("1.0.0-beta")! < AppVersion("1.0.0-beta.1")!)
        #expect(AppVersion("1.0.0-1")! < AppVersion("1.0.0-alpha")!)
        #expect(AppVersion("1.0.1-rc.1")! > AppVersion("1.0.0")!)
    }
}

@Suite struct UpdateCheckerTests {
    private func check(_ fetcher: FakeFetcher, current: String = "0.1.0") async -> UpdateCheckResult {
        await UpdateChecker(current: AppVersion(current)!, fetcher: fetcher).check()
    }

    @Test func offersANewerRelease() async {
        let result = await check(FakeFetcher(body: release()))
        guard case .available(let info) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(info.version.description == "0.2.0")
        #expect(info.tag == "v0.2.0")
        #expect(info.downloadURL?.lastPathComponent == "SpaceLens-0.2.0.dmg", "the dmg wins over the zip")
        #expect(info.pageURL.absoluteString == "https://github.com/o/r/releases/tag/v0.2.0")
        #expect(info.publishedAt != nil)
    }

    @Test func sameOrOlderMeansUpToDate() async {
        #expect(await check(FakeFetcher(body: release()), current: "0.2.0") == .upToDate)
        #expect(await check(FakeFetcher(body: release()), current: "0.3.0") == .upToDate)
    }

    @Test func fallsBackToTheZipWhenThereIsNoDmg() async {
        let assets =
            #"[{"name":"SpaceLens-0.2.0.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/SpaceLens-0.2.0.zip"}]"#
        guard case .available(let info) = await check(FakeFetcher(body: release(assets: assets))) else {
            Issue.record("expected an update")
            return
        }
        #expect(info.downloadURL?.pathExtension == "zip")
        guard case .available(let bare) = await check(FakeFetcher(body: release(assets: "[]"))) else {
            Issue.record("expected an update")
            return
        }
        #expect(bare.downloadURL == nil)
    }

    @Test func draftsAndPrereleasesAreIgnored() async {
        for body in [release(draft: true), release(prerelease: true), release(tag: "v0.2.0-beta.1")] {
            let result = await check(FakeFetcher(body: body))
            if case .available = result { Issue.record("must not offer \(body)") }
        }
    }

    @Test func linksOutsideGitHubAreRefused() async {
        for page in [
            "http://github.com/o/r", "https://evil.example/github.com", "https://github.com.evil.example/x",
            "javascript:alert(1)", "file:///etc/passwd",
        ] {
            let result = await check(FakeFetcher(body: release(page: page)))
            if case .available = result { Issue.record("must not trust \(page)") }
        }
        let assets = #"[{"name":"x.dmg","browser_download_url":"https://evil.example/x.dmg"}]"#
        guard case .available(let info) = await check(FakeFetcher(body: release(assets: assets))) else {
            Issue.record("the release page is fine, only the download is dropped")
            return
        }
        #expect(info.downloadURL == nil)
    }

    @Test func failuresAreReportedNotThrown() async {
        #expect(await check(FakeFetcher(status: 404)) == .upToDate)
        for status in [403, 429, 500, 503] {
            guard case .failed = await check(FakeFetcher(status: status)) else {
                Issue.record("status \(status) should fail")
                continue
            }
        }
        guard case .failed = await check(FakeFetcher(body: "not json")) else {
            Issue.record("garbage")
            return
        }
        guard case .failed = await check(FakeFetcher(error: URLError(.notConnectedToInternet))) else {
            Issue.record("offline")
            return
        }
    }

    @Test func asksTheRightEndpoint() {
        let checker = UpdateChecker(repository: "a/b", current: AppVersion("1.0.0")!, fetcher: FakeFetcher())
        #expect(checker.endpoint.absoluteString == "https://api.github.com/repos/a/b/releases/latest")
    }
}
