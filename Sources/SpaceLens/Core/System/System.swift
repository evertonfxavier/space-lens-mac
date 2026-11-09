import Darwin
import Foundation
import LocalAuthentication

public struct DiskUsage: Codable, Sendable, Equatable {
    public var total: Int64
    /// What Finder calls "available": free space plus purgeable space the system gives back when needed.
    public var availableImportant: Int64
    public var availableRaw: Int64

    public var used: Int64 { max(0, total - availableImportant) }
    public var purgeable: Int64 { max(0, availableImportant - availableRaw) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public init(total: Int64, availableImportant: Int64, availableRaw: Int64) {
        self.total = total
        self.availableImportant = availableImportant
        self.availableRaw = availableRaw
    }
}

public enum DiskInfo {
    public static func current(path: String = "/") -> DiskUsage? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity
        else { return nil }
        let raw = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? raw
        return DiskUsage(total: Int64(total), availableImportant: important, availableRaw: raw)
    }
}

public enum FullDiskAccess {
    /// The TCC database is readable only with Full Disk Access, and probing it never shows a prompt.
    public static func isGranted() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

// MARK: - Touch ID / password gate

public enum AuthOutcome: Sendable, Equatable {
    case approved
    case cancelled
    /// The Mac has no password or biometrics set, so there is nothing to ask for.
    case unavailable
    case failed(String)

    public var isGranted: Bool { self == .approved || self == .unavailable }
}

public protocol AuthGate: Sendable {
    func authenticate(reason: String) async -> AuthOutcome
}

/// Asks macOS for Touch ID, Apple Watch or the login password (`.deviceOwnerAuthentication`). The system dialog
/// offers whichever the Mac supports; SpaceLens only receives yes or no.
public struct LocalAuthGate: AuthGate {
    public init() {}

    public func authenticate(reason: String) async -> AuthOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .approved : .cancelled
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Time Machine local snapshots

public enum TimeMachineSnapshots {
    /// Dates like `2026-11-08-123456`, from `tmutil listlocalsnapshotdates /`.
    public static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil }
    }

    public static func recommendation(dates: [String]) -> Recommendation? {
        guard !dates.isEmpty else { return nil }
        let items = dates.sorted().map {
            CleanupItem(path: "snapshot:\($0)", size: 0, label: $0, argument: $0, preselected: false)
        }
        return Recommendation(
            id: "snapshots.tm", title: "Instantâneos locais do Time Machine",
            explanation:
                "Cópias de segurança que o Time Machine guarda no próprio Mac enquanto o disco de backup não está conectado. O macOS apaga sozinho quando falta espaço, mas elas podem ocupar muitos GB antes disso.",
            consequence:
                "Pede sua senha ou digital. Você perde só a possibilidade de restaurar versões antigas deste Mac sem o disco de backup.",
            category: .backups, safety: .review, mode: .delete, items: items,
            command: CommandSpec(tool: "tmutil", args: ["deletelocalsnapshots"], admin: true), needsAdmin: true,
            preselect: false, sizeIsReference: true)
    }
}
