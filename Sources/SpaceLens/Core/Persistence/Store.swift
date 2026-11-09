import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public enum ScanScope: String, Codable, CaseIterable, Sendable {
        case home
        case wholeDisk

        public var title: String { self == .home ? L("Minha pasta pessoal") : L("Disco inteiro") }
    }

    /// Ask for Touch ID / password before cleaning (not for unattended routines, which only do safe things).
    public var requireAuthToClean = true
    public var scope: ScanScope = .home
    /// Hours between automatic scans. 0 turns it off.
    public var autoScanHours = 24
    public var showFreeSpaceInMenuBar = true
    public var lowSpaceThresholdGB = 20
    /// Move to the Trash even what the catalog says is safe to delete for good.
    public var alwaysUseTrash = false
    public var notifications = true
    /// Interface language. `.system` follows the macOS language list.
    public var language: AppLanguage = .system
    /// The menu bar icon and its popover. Off keeps SpaceLens in the Dock instead.
    public var showMenuBarItem = true
    /// Look for a newer GitHub release once a day.
    public var checkForUpdates = true
    public var lastUpdateCheck: Date?
    /// Tag of the release whose banner you dismissed. A newer release shows its banner again.
    public var dismissedUpdate: String?

    public init() {}

    // Missing keys fall back to defaults so an older settings file keeps loading.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        requireAuthToClean = try c.decodeIfPresent(Bool.self, forKey: .requireAuthToClean) ?? requireAuthToClean
        scope = try c.decodeIfPresent(ScanScope.self, forKey: .scope) ?? scope
        autoScanHours = try c.decodeIfPresent(Int.self, forKey: .autoScanHours) ?? autoScanHours
        showFreeSpaceInMenuBar =
            try c.decodeIfPresent(Bool.self, forKey: .showFreeSpaceInMenuBar) ?? showFreeSpaceInMenuBar
        lowSpaceThresholdGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceThresholdGB) ?? lowSpaceThresholdGB
        alwaysUseTrash = try c.decodeIfPresent(Bool.self, forKey: .alwaysUseTrash) ?? alwaysUseTrash
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? language
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? showMenuBarItem
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? checkForUpdates
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        dismissedUpdate = try c.decodeIfPresent(String.self, forKey: .dismissedUpdate)
    }

    private enum Keys: String, CodingKey {
        case requireAuthToClean, scope, autoScanHours, showFreeSpaceInMenuBar, lowSpaceThresholdGB, alwaysUseTrash,
            notifications, language, showMenuBarItem, checkForUpdates, lastUpdateCheck, dismissedUpdate
    }
}

/// What the last scan found, kept on disk so the menu bar has numbers before any new scan.
public struct ScanSummary: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var size: Int64
        public var safety: Safety
    }

    public var date: Date
    public var scope: AppSettings.ScanScope
    public var categoryBytes: [String: Int64]
    public var safeFreeable: Int64
    public var top: [Item]
    public var deniedCount: Int
    public var duration: TimeInterval

    public init(
        date: Date, scope: AppSettings.ScanScope, categoryBytes: [String: Int64], safeFreeable: Int64, top: [Item],
        deniedCount: Int, duration: TimeInterval
    ) {
        self.date = date
        self.scope = scope
        self.categoryBytes = categoryBytes
        self.safeFreeable = safeFreeable
        self.top = top
        self.deniedCount = deniedCount
        self.duration = duration
    }

    public init(result: ScanResult, analysis: Analysis, scope: AppSettings.ScanScope) {
        self.init(
            date: result.finishedAt, scope: scope,
            categoryBytes: Dictionary(uniqueKeysWithValues: analysis.categoryBytes.map { ($0.key.rawValue, $0.value) }),
            safeFreeable: analysis.safeFreeable,
            top: analysis.recommendations.filter { $0.safety == .safe && !$0.needsAdmin && !$0.sizeIsReference }
                .prefix(4).map { Item(id: $0.id, title: $0.title, size: $0.totalSize, safety: $0.safety) },
            deniedCount: result.deniedCount, duration: result.duration)
    }
}

/// Atomic JSON files in `~/Library/Application Support/SpaceLens`. A corrupt or missing file loads as the default.
public struct JSONStore<Value: Codable>: Sendable where Value: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load(default fallback: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Value.self, from: data)) ?? fallback
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func directory(named name: String = "SpaceLens") -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
}
