import Foundation
import UserNotifications

public protocol Notifier: Sendable {
    func notify(title: String, body: String) async
}

public struct SystemNotifier: Notifier {
    public init() {}

    public func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Runs one routine unattended. It scans only what the task needs, keeps to the recommendations the task names,
/// never asks for a password (system items are skipped) and only deletes for good what the catalog says is
/// regenerable: everything else goes to the Trash. Whatever it does ends up in a `RunRecord`.
public final class RoutineRunner: @unchecked Sendable {
    private struct Outcome {
        var message: String
        var applied = false
        var freed: Int64 = 0
        var trashed: Int64 = 0
        var potential: Int64 = 0
        var count = 0
        var failed = false
        /// Worth interrupting you for.
        var notable = false
    }

    private typealias Selection = [(recommendation: Recommendation, items: [CleanupItem])]

    private let home: String
    private let cleaner: Cleaner
    private let notifier: Notifier
    private let disk: @Sendable () -> DiskUsage?
    private let toolExists: @Sendable (String) -> Bool
    private let minNodeSize: Int64

    public init(
        home: String, cleaner: Cleaner, notifier: Notifier,
        disk: @escaping @Sendable () -> DiskUsage? = { DiskInfo.current() },
        toolExists: @escaping @Sendable (String) -> Bool = { _ in false }, minNodeSize: Int64 = 1 << 20
    ) {
        self.home = home
        self.cleaner = cleaner
        self.notifier = notifier
        self.disk = disk
        self.toolExists = toolExists
        self.minNodeSize = minNodeSize
    }

    public func run(_ routine: Routine, at date: Date = Date()) async -> RunRecord {
        let outcome = await execute(routine, at: date)
        if routine.notify, outcome.notable || outcome.failed {
            await notifier.notify(title: routine.name, body: outcome.message)
        }
        return RunRecord(
            routineID: routine.id, routineName: routine.name, date: date, applied: outcome.applied,
            freed: outcome.freed, trashed: outcome.trashed, potential: outcome.potential, itemCount: outcome.count,
            message: outcome.message, failed: outcome.failed)
    }

    // MARK: Tasks

    private func execute(_ routine: Routine, at date: Date) async -> Outcome {
        switch routine.task {
        case .cleanCaches(let minAge):
            let selection = select(
                roots: safeCacheRoots(), keep: { Self.isPlainSafeCache($0) }, age: { $0.modified }, olderThan: minAge,
                at: date)
            return await finish(routine, selection)

        case .emptyTrash(let days):
            let selection = select(
                roots: [home + "/.Trash"], keep: { $0.id == "trash.items" }, age: { $0.changed ?? $0.modified },
                olderThan: days, at: date)
            return await finish(routine, selection)

        case .cleanDownloads(let days, let installersOnly):
            let ids: Set<String> =
                installersOnly ? ["downloads.installers"] : ["downloads.installers", "downloads.old"]
            let selection = select(
                roots: [home + "/Downloads"], keep: { ids.contains($0.id) }, age: { $0.modified }, olderThan: days,
                at: date)
            return await finish(routine, selection)

        case .cleanProjectArtifacts(let roots, let days):
            let selection = select(
                roots: roots, keep: { $0.id.hasPrefix("artifact.") }, age: { $0.modified }, olderThan: days, at: date)
            return await finish(routine, selection)

        case .lowSpaceAlert(let gb):
            guard let usage = disk() else {
                return Outcome(message: "Não consegui ler o espaço do disco.", failed: true)
            }
            guard usage.availableImportant < Int64(gb) << 30 else {
                return Outcome(message: "Espaço livre ok: \(ByteFormat.string(usage.availableImportant)).")
            }
            let selection = select(
                roots: safeCacheRoots(), keep: { Self.isPlainSafeCache($0) }, age: { _ in nil }, olderThan: 0, at: date)
            let potential = selection.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.size } }
            let hint =
                potential > 0
                ? "Dá para liberar \(ByteFormat.string(potential)) com segurança."
                : "Abra o SpaceLens para ver o que ocupa espaço."
            return Outcome(
                message: "Restam \(ByteFormat.string(usage.availableImportant)) livres (limite \(gb) GB). \(hint)",
                potential: potential, count: selection.reduce(0) { $0 + $1.items.count }, notable: true)
        }
    }

    /// App caches and logs that are safe and need no password or tool: the only thing an unattended routine
    /// deletes for good. Developer caches (npm, cargo…) are left alone because people work offline.
    private static func isPlainSafeCache(_ r: Recommendation) -> Bool {
        r.category == .caches && r.safety == .safe && !r.needsAdmin && !r.isCommand
    }

    private func safeCacheRoots() -> [String] {
        Catalog.entries(home: home)
            .filter {
                $0.actionable && $0.category == .caches && $0.safety == .safe && !$0.admin && $0.command == nil
            }
            .flatMap(\.matches)
            .map { match in
                switch match {
                case .path(let path): return path
                case .childrenOf(let path): return path
                }
            }
    }

    private func select(
        roots: [String], keep: (Recommendation) -> Bool, age: (CleanupItem) -> Date?, olderThan days: Int, at date: Date
    ) -> Selection {
        let existing = Array(Set(roots)).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [] }
        let options = ScanOptions(roots: existing, minNodeSize: minNodeSize, minFileSize: minNodeSize)
        let scan = DiskScanner(options: options).scan()
        let analysis = Analyzer(home: home, now: date, toolExists: toolExists).analyze(scan.roots)
        let cutoff = date.addingTimeInterval(-Double(days) * 86_400)
        var taken = Set<String>()
        var out: Selection = []
        for recommendation in analysis.recommendations where keep(recommendation) {
            let items = recommendation.items.filter { item in
                guard !taken.contains(item.path) else { return false }
                guard days > 0, let when = age(item) else { return true }
                return when < cutoff
            }
            for item in items { taken.insert(item.path) }
            if !items.isEmpty { out.append((recommendation, items)) }
        }
        return out
    }

    private func finish(_ routine: Routine, _ selection: Selection) async -> Outcome {
        let potential = selection.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.size } }
        let count = selection.reduce(0) { $0 + $1.items.count }
        guard count > 0 else { return Outcome(message: "Nada para limpar.", applied: routine.apply) }
        guard routine.apply else {
            return Outcome(
                message:
                    "Poderia liberar \(ByteFormat.string(potential)) em \(count) item(ns). A rotina está em modo “só avisar”.",
                potential: potential, count: count, notable: true)
        }
        var outcome = Outcome(message: "", applied: true)
        var failures = 0
        for (recommendation, items) in selection {
            let result = await cleaner.perform(recommendation, selected: items, forceTrash: false, allowAdmin: false)
            outcome.freed += result.freed
            outcome.trashed += result.trashed
            outcome.count += result.removedCount
            failures += result.failures.count
        }
        outcome.message =
            outcome.count == 0
            ? "Nada foi removido." : "Liberou \(ByteFormat.string(outcome.freed)) em \(outcome.count) item(ns)."
        if outcome.trashed > 0 {
            outcome.message += " \(ByteFormat.string(outcome.trashed)) foram para a Lixeira (esvazie para liberar)."
        }
        if failures > 0 { outcome.message += " \(failures) item(ns) não puderam ser removidos." }
        outcome.failed = failures > 0 && outcome.count == 0
        outcome.notable = outcome.freed > 0 || outcome.trashed > 0
        return outcome
    }
}
