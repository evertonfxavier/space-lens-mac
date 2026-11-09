import Foundation

/// `1.2.3` or `1.2.3-beta.1`, optionally prefixed with `v`. Follows semantic versioning precedence.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") { raw.removeFirst() }
        if let plus = raw.firstIndex(of: "+") { raw = String(raw[..<plus]) }  // build metadata does not count
        var pre: [String] = []
        if let dash = raw.firstIndex(of: "-") {
            pre = raw[raw.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(
                String.init)
            raw = String(raw[..<dash])
            guard !pre.isEmpty, !pre.contains(where: \.isEmpty) else { return nil }
        }
        let numbers = raw.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
            major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A pre-release is older than the release it leads to.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case (let p?, let q?): return p < q
            case (.some, nil): return true  // numeric identifiers rank below alphanumeric ones
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var tag: String
    public var name: String
    public var pageURL: URL
    /// The `.dmg` of the release when there is one, else the `.zip`.
    public var downloadURL: URL?
    public var notes: String
    public var publishedAt: Date?
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
    case failed(String)
}

public protocol HTTPFetching: Sendable {
    /// Returns the body and the HTTP status code.
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    private let userAgent: String

    public init(userAgent: String) { self.userAgent = userAgent }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Asks the public GitHub API whether a newer release exists. It sends nothing about you: one anonymous GET.
public struct UpdateChecker: Sendable {
    public static let defaultRepository = "evertonfxavier/space-lens-mac"

    public let repository: String
    public let current: AppVersion
    private let fetcher: HTTPFetching

    public init(repository: String = defaultRepository, current: AppVersion, fetcher: HTTPFetching) {
        self.repository = repository
        self.current = current
        self.fetcher = fetcher
    }

    public var endpoint: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    public func check() async -> UpdateCheckResult {
        do {
            let (data, status) = try await fetcher.get(endpoint)
            switch status {
            case 200: break
            case 404: return .upToDate  // no published release yet
            case 403, 429: return .failed(L("O GitHub limitou as consultas. Tente de novo mais tarde."))
            default: return .failed(L("O GitHub respondeu com o código %lld.", status))
            }
            guard let release = Self.parse(data) else { return .failed(L("Resposta inesperada do GitHub.")) }
            return release.version > current ? .available(release) : .upToDate
        } catch {
            return .failed(L("Sem conexão com o GitHub."))
        }
    }

    /// Drafts and pre-releases are never offered. Links must be https and on github.com: they are opened in the
    /// browser, so a tampered response must not be able to send you somewhere else.
    static func parse(_ data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                var name: String
                var downloadURL: String
                enum CodingKeys: String, CodingKey {
                    case name
                    case downloadURL = "browser_download_url"
                }
            }
            var tag: String
            var name: String?
            var pageURL: String
            var body: String?
            var draft: Bool?
            var prerelease: Bool?
            var publishedAt: String?
            var assets: [Asset]?
            enum CodingKeys: String, CodingKey {
                case tag = "tag_name"
                case name, body, draft, prerelease, assets
                case pageURL = "html_url"
                case publishedAt = "published_at"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.draft != true, payload.prerelease != true,
            let version = AppVersion(payload.tag), version.prerelease.isEmpty,
            let page = trustedURL(payload.pageURL)
        else { return nil }
        let assets = payload.assets ?? []
        let download =
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return ReleaseInfo(
            version: version, tag: payload.tag, name: payload.name ?? payload.tag, pageURL: page,
            downloadURL: download.flatMap { trustedURL($0.downloadURL) }, notes: payload.body ?? "",
            publishedAt: payload.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    static func trustedURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
            host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }
        return url
    }
}
