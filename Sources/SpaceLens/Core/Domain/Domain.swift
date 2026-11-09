import Foundation

/// How sure we are that something can go away.
public enum Safety: Int, Codable, Comparable, CaseIterable, Sendable {
    /// The system or the app recreates it by itself. Nothing of yours is lost.
    case safe = 0
    /// Might be yours. Look before deleting.
    case review = 1
    /// System or irreplaceable data. SpaceLens refuses to touch it.
    case keep = 2

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .safe: return L("Pode apagar")
        case .review: return L("Revise antes")
        case .keep: return L("Não apague")
        }
    }
}

public enum Category: String, Codable, CaseIterable, Sendable {
    case caches, developer, trash, downloads, media, documents, apps, appData, messages, backups
    case virtualization, cloud, system, other

    public var title: String {
        switch self {
        case .caches: return L("Caches e Logs")
        case .developer: return L("Desenvolvimento")
        case .trash: return L("Lixeira")
        case .downloads: return L("Downloads")
        case .media: return L("Fotos, Vídeos e Música")
        case .documents: return L("Documentos")
        case .apps: return L("Aplicativos")
        case .appData: return L("Dados de Apps")
        case .messages: return L("Mensagens e E-mail")
        case .backups: return L("Backups")
        case .virtualization: return L("Máquinas Virtuais e Docker")
        case .cloud: return L("Nuvem (iCloud, OneDrive…)")
        case .system: return L("Sistema")
        case .other: return L("Outros")
        }
    }
}

/// Moving to the Trash can be undone but frees nothing until the Trash is emptied.
public enum RemovalMode: String, Codable, Sendable {
    case trash
    case delete
}

/// A tool SpaceLens runs instead of deleting paths itself (docker prune, simctl, brew cleanup, tmutil…).
public struct CommandSpec: Codable, Hashable, Sendable {
    public var tool: String
    public var args: [String]
    public var admin: Bool

    public init(tool: String, args: [String], admin: Bool = false) {
        self.tool = tool
        self.args = args
        self.admin = admin
    }

    public var display: String { ([tool] + args).joined(separator: " ") }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date?
    public var changed: Date?
    /// Extra context, for example the project that owns a node_modules.
    public var label: String?
    /// Only for command items such as a Time Machine snapshot date.
    public var argument: String?
    /// Whether the item starts ticked. Active projects and recent files start unticked.
    public var preselected: Bool

    public var id: String { path }

    public init(
        path: String, size: Int64, modified: Date? = nil, changed: Date? = nil, label: String? = nil,
        argument: String? = nil, preselected: Bool = true
    ) {
        self.path = path
        self.size = size
        self.modified = modified
        self.changed = changed
        self.label = label
        self.argument = argument
        self.preselected = preselected
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct Recommendation: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String
    public var consequence: String
    public var category: Category
    public var safety: Safety
    public var mode: RemovalMode
    public var items: [CleanupItem]
    public var command: CommandSpec?
    public var needsAdmin: Bool
    public var preselect: Bool
    /// Space freed by a command cannot be known beforehand; the size is only a reference.
    public var sizeIsReference: Bool

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var isCommand: Bool { command != nil }
}

public struct NodeClass: Sendable, Equatable {
    public var category: Category
    public var safety: Safety
    public var title: String?
    public var explanation: String?
    public var consequence: String?
    public var entryID: String?

    public static var unknown: NodeClass {
        NodeClass(
            category: .other, safety: .review, title: nil,
            explanation:
                L("Arquivos seus ou de um app. O SpaceLens não sabe se podem ser recriados — confira antes de apagar."),
            consequence: nil, entryID: nil)
    }
}

public enum ByteFormat {
    /// Sizes in the interface language ("61,8 GB" in Portuguese and Spanish, "61.8 GB" in English).
    public static func string(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        if value < 1000 { return value == 0 ? "0 KB" : "1 KB" }
        let style = ByteCountFormatStyle(
            style: .file, allowedUnits: [.kb, .mb, .gb, .tb], spellsOutZero: false, includesActualByteCount: false,
            locale: Localizer.shared.locale)
        return style.format(value).replacingOccurrences(of: "kB", with: "KB")
    }
}
