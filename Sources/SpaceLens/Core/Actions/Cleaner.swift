import Darwin
import Foundation

// MARK: - Ports

public protocol FileOperations: Sendable {
    func trash(_ path: String) throws
    func remove(_ path: String) throws
    func exists(_ path: String) -> Bool
}

public struct SystemFileOperations: FileOperations {
    public init() {}

    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    public func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    /// `lstat`, so a dangling symlink still counts as existing.
    public func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var output: String
}

public protocol CommandRunning: Sendable {
    func resolve(_ tool: String) -> String?
    func run(executable: String, args: [String]) async -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    private let searchPaths: [String]
    private let timeout: TimeInterval

    public init(
        searchPaths: [String] = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            NSHomeDirectory() + "/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin",
        ], timeout: TimeInterval = 900
    ) {
        self.searchPaths = searchPaths
        self.timeout = timeout
    }

    public func resolve(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPaths {
            let candidate = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(executable: String, args: [String]) async -> CommandResult {
        let searchPaths = self.searchPaths
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPaths.joined(separator: ":")
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: data.suffix(4000), as: UTF8.self)
                continuation.resume(returning: CommandResult(status: process.terminationStatus, output: text))
            }
        }
    }
}

// MARK: - Result

public struct CleanupFailure: Sendable, Equatable {
    public var path: String
    public var reason: String
}

public struct CleanupResult: Sendable {
    /// Bytes removed for good.
    public var freed: Int64 = 0
    /// Bytes moved to the Trash: nothing is free until the Trash is emptied.
    public var trashed: Int64 = 0
    public var removedPaths: [String] = []
    public var failures: [CleanupFailure] = []
    /// You dismissed the password / Touch ID dialog.
    public var cancelled = false
    public var usedAdmin = false
    public var note: String?

    public var removedCount: Int { removedPaths.count }
    public init() {}
}

// MARK: - Cleaner

/// Applies a recommendation. Every path goes through `SafetyGuard` first; protected paths are refused even if
/// something upstream asked for them. A permission error is retried as administrator only for the system caches
/// and logs the guard allows, in one batch (one password / Touch ID prompt).
public final class Cleaner: @unchecked Sendable {
    private let guardrail: SafetyGuard
    private let files: FileOperations
    private let privileged: PrivilegedRunner
    private let commands: CommandRunning
    private let freeBytes: @Sendable () -> Int64

    public init(
        guardrail: SafetyGuard, files: FileOperations = SystemFileOperations(),
        privileged: PrivilegedRunner = AdminPromptRunner(), commands: CommandRunning = ProcessCommandRunner(),
        freeBytes: @escaping @Sendable () -> Int64 = { DiskInfo.current()?.availableImportant ?? 0 }
    ) {
        self.guardrail = guardrail
        self.files = files
        self.privileged = privileged
        self.commands = commands
        self.freeBytes = freeBytes
    }

    /// Cleans the selected items of a recommendation. `forceTrash` overrides the recommendation's mode with
    /// the recoverable one (never for system items, which cannot go to the Trash).
    public func perform(
        _ recommendation: Recommendation, selected: [CleanupItem], forceTrash: Bool = false, allowAdmin: Bool = true
    ) async -> CleanupResult {
        let known = Set(recommendation.items.map(\.path))
        var result = CleanupResult()
        let valid = selected.filter { known.contains($0.path) }
        for item in selected where !known.contains(item.path) {
            result.failures.append(CleanupFailure(path: item.path, reason: L("Item não pertence à recomendação.")))
        }
        guard !valid.isEmpty else { return result }

        if let command = recommendation.command {
            return await runCommand(command, items: valid, allowAdmin: allowAdmin, into: result)
        }
        let mode: RemovalMode = (forceTrash && !recommendation.needsAdmin) ? .trash : recommendation.mode
        return await remove(valid, mode: mode, origin: .catalog, allowAdmin: allowAdmin, into: result)
    }

    /// Moves things you picked yourself in the explorer to the Trash.
    public func trashManually(_ items: [CleanupItem]) async -> CleanupResult {
        await remove(items, mode: .trash, origin: .manual, allowAdmin: false, into: CleanupResult())
    }

    // MARK: Paths

    func remove(
        _ items: [CleanupItem], mode: RemovalMode, origin: SafetyGuard.Origin, allowAdmin: Bool,
        into start: CleanupResult
    ) async -> CleanupResult {
        var result = start
        var needsAdmin: [CleanupItem] = []
        for item in items {
            if case .denied(let reason) = guardrail.check(item.path, mode: mode, origin: origin) {
                result.failures.append(CleanupFailure(path: item.path, reason: reason))
                continue
            }
            guard files.exists(item.path) else { continue }
            do {
                switch mode {
                case .trash:
                    try files.trash(item.path)
                    result.trashed += item.size
                case .delete:
                    try files.remove(item.path)
                    result.freed += item.size
                }
                result.removedPaths.append(item.path)
            } catch {
                if Self.isPermission(error), allowAdmin, mode == .delete, guardrail.mayEscalate(item.path) {
                    needsAdmin.append(item)
                } else {
                    result.failures.append(
                        CleanupFailure(path: item.path, reason: Self.describe(error, path: item.path)))
                }
            }
        }
        guard !needsAdmin.isEmpty else { return result }

        result.usedAdmin = true
        let batches = stride(from: 0, to: needsAdmin.count, by: 100).map {
            Array(needsAdmin[$0..<min($0 + 100, needsAdmin.count)])
        }
        let prompt = L("O SpaceLens precisa da sua permissão para apagar %lld item(ns) de sistema.", needsAdmin.count)
        do {
            try await privileged.run(
                commands: batches.map { ["/bin/rm", "-rf", "--"] + $0.map(\.path) }, prompt: prompt)
        } catch PrivilegedError.cancelled {
            result.cancelled = true
        } catch {
            result.note = "\(error)"
        }
        for item in needsAdmin {
            if files.exists(item.path) {
                result.failures.append(
                    CleanupFailure(
                        path: item.path,
                        reason: result.cancelled ? L("Autorização cancelada.") : L("Não foi possível apagar.")))
            } else {
                result.freed += item.size
                result.removedPaths.append(item.path)
            }
        }
        return result
    }

    // MARK: Commands

    private func runCommand(
        _ command: CommandSpec, items: [CleanupItem], allowAdmin: Bool, into start: CleanupResult
    ) async -> CleanupResult {
        var result = start
        guard let executable = commands.resolve(command.tool) else {
            result.failures.append(
                CleanupFailure(path: command.tool, reason: L("“%@” não está instalado.", command.tool)))
            return result
        }
        let argumentsPerItem = items.contains { $0.argument != nil }
        let invocations: [(CleanupItem?, [String])] =
            argumentsPerItem
            ? items.compactMap { item in item.argument.map { (item, command.args + [$0]) } } : [(nil, command.args)]

        if command.admin {
            guard allowAdmin else {
                result.failures.append(CleanupFailure(path: command.display, reason: L("Precisa de autorização.")))
                return result
            }
            result.usedAdmin = true
            do {
                try await privileged.run(
                    commands: invocations.map { [executable] + $0.1 },
                    prompt: L("O SpaceLens precisa da sua permissão para executar “%@”.", command.display))
                result.removedPaths.append(contentsOf: invocations.map { $0.0?.path ?? command.display })
            } catch PrivilegedError.cancelled {
                result.cancelled = true
            } catch {
                result.failures.append(CleanupFailure(path: command.display, reason: "\(error)"))
            }
            return result
        }

        let before = freeBytes()
        for (item, args) in invocations {
            let outcome = await commands.run(executable: executable, args: args)
            if outcome.status == 0 {
                result.removedPaths.append(item?.path ?? command.display)
            } else {
                let tail = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
                result.failures.append(
                    CleanupFailure(
                        path: command.display, reason: tail.isEmpty ? L("Código %lld.", Int(outcome.status)) : tail))
            }
        }
        result.freed = max(0, freeBytes() - before)
        return result
    }

    // MARK: Errors

    static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(EACCES) || ns.code == Int(EPERM) }
        if ns.code == NSFileWriteNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(underlying) }
        return false
    }

    static func describe(_ error: Error, path: String) -> String {
        if isPermission(error) {
            return L("Permissão negada. Conceda “Acesso Total ao Disco” ao SpaceLens em Ajustes do Sistema.")
        }
        return (error as NSError).localizedDescription
    }
}
