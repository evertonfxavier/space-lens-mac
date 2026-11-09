import Foundation
import Testing

// MARK: - Fakes

final class FakeFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var existing: Set<String>
    private(set) var trashed: [String] = []
    private(set) var removed: [String] = []
    var failures: [String: Error] = [:]

    init(existing: [String]) { self.existing = Set(existing) }

    func trash(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = failures[path] { throw error }
        existing.remove(path)
        trashed.append(path)
    }

    func remove(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = failures[path] { throw error }
        existing.remove(path)
        removed.append(path)
    }

    func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return existing.contains(path)
    }

    /// What the privileged `rm` would do.
    func removeAsRoot(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for path in paths { existing.remove(path) }
    }
}

final class FakePrivileged: PrivilegedRunner, @unchecked Sendable {
    var calls: [[[String]]] = []
    var prompts: [String] = []
    var error: PrivilegedError?
    var files: FakeFiles?

    func run(commands: [[String]], prompt: String) async throws {
        calls.append(commands)
        prompts.append(prompt)
        if let error { throw error }
        for argv in commands where argv.first == "/bin/rm" { files?.removeAsRoot(Array(argv.dropFirst(3))) }
    }
}

final class FakeCommands: CommandRunning, @unchecked Sendable {
    var installed: Set<String>
    var results: [CommandResult] = []
    var runs: [(String, [String])] = []
    init(installed: Set<String> = []) { self.installed = installed }

    func resolve(_ tool: String) -> String? { installed.contains(tool) ? "/usr/bin/" + tool : nil }

    func run(executable: String, args: [String]) async -> CommandResult {
        runs.append((executable, args))
        return results.isEmpty ? CommandResult(status: 0, output: "") : results.removeFirst()
    }
}

private func permissionDenied() -> Error { NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }

private func recommendation(
    _ id: String = "caches.user", mode: RemovalMode = .delete, admin: Bool = false, command: CommandSpec? = nil,
    paths: [String]
) -> Recommendation {
    Recommendation(
        id: id, title: id, explanation: "e", consequence: "c", category: .caches, safety: .safe, mode: mode,
        items: paths.enumerated().map { CleanupItem(path: $1, size: Int64(($0 + 1) * 1000), argument: nil) },
        command: command, needsAdmin: admin, preselect: true, sizeIsReference: command != nil)
}

// MARK: - Tests

@Suite struct CleanerTests {
    private let home = "/Users/me"
    private func cleaner(
        _ files: FakeFiles, privileged: FakePrivileged = FakePrivileged(), commands: FakeCommands = FakeCommands(),
        free: @escaping @Sendable () -> Int64 = { 0 }
    ) -> Cleaner {
        privileged.files = files
        return Cleaner(
            guardrail: SafetyGuard(home: home), files: files, privileged: privileged, commands: commands,
            freeBytes: free)
    }

    @Test func deletesSelectedItemsAndCountsFreedBytes() async {
        let paths = [home + "/Library/Caches/a", home + "/Library/Caches/b", home + "/Library/Caches/c"]
        let files = FakeFiles(existing: paths)
        let rec = recommendation(paths: paths)
        let result = await cleaner(files).perform(rec, selected: Array(rec.items.prefix(2)))
        #expect(files.removed == Array(paths.prefix(2)))
        #expect(files.exists(paths[2]), "unselected item stays")
        #expect(result.freed == 3000 && result.trashed == 0 && result.removedCount == 2 && result.failures.isEmpty)
    }

    @Test func forceTrashMovesInsteadOfDeletingAndFreesNothingYet() async {
        let paths = [home + "/Library/Caches/a"]
        let files = FakeFiles(existing: paths)
        let rec = recommendation(paths: paths)
        let result = await cleaner(files).perform(rec, selected: rec.items, forceTrash: true)
        #expect(files.trashed == paths && files.removed.isEmpty)
        #expect(result.freed == 0 && result.trashed == 1000)
    }

    @Test func reviewRecommendationsDefaultToTheTrash() async {
        let paths = [home + "/Downloads/x.dmg"]
        let files = FakeFiles(existing: paths)
        let rec = recommendation("downloads.installers", mode: .trash, paths: paths)
        let result = await cleaner(files).perform(rec, selected: rec.items)
        #expect(files.trashed == paths && result.trashed == 1000 && result.freed == 0)
    }

    @Test func refusesProtectedPathsEvenInsideARecommendation() async {
        let paths = [
            "/System/Library/CoreServices", home + "/Library", home + "/.ssh/id_rsa", home + "/Library/Caches/ok",
        ]
        let files = FakeFiles(existing: paths)
        let rec = recommendation(paths: paths)
        let result = await cleaner(files).perform(rec, selected: rec.items)
        #expect(files.removed == [home + "/Library/Caches/ok"])
        #expect(result.failures.map(\.path) == Array(paths.prefix(3)))
        #expect(files.exists("/System/Library/CoreServices"))
    }

    @Test func refusesItemsThatAreNotPartOfTheRecommendation() async {
        let files = FakeFiles(existing: [home + "/Library/Caches/a", home + "/Documents/precious"])
        let rec = recommendation(paths: [home + "/Library/Caches/a"])
        let sneaky = CleanupItem(path: home + "/Documents/precious", size: 1)
        let result = await cleaner(files).perform(rec, selected: rec.items + [sneaky])
        #expect(files.removed == [home + "/Library/Caches/a"])
        #expect(files.exists(home + "/Documents/precious"))
        #expect(result.failures.first?.reason == "Item não pertence à recomendação.")
    }

    @Test func permissionErrorInHomeIsReportedWithoutEscalating() async {
        let path = home + "/Library/Caches/rootowned"
        let files = FakeFiles(existing: [path])
        files.failures[path] = permissionDenied()
        let privileged = FakePrivileged()
        let rec = recommendation(paths: [path])
        let result = await cleaner(files, privileged: privileged).perform(rec, selected: rec.items)
        #expect(privileged.calls.isEmpty, "no password prompt for something inside the home folder")
        #expect(result.failures.first?.reason.contains("Acesso Total ao Disco") == true)
        #expect(!result.usedAdmin)
    }

    @Test func systemItemsEscalateOnceInOneBatch() async {
        let paths = ["/Library/Caches/com.a", "/Library/Caches/com.b", "/Library/Logs/x.log"]
        let files = FakeFiles(existing: paths)
        for p in paths { files.failures[p] = permissionDenied() }
        let privileged = FakePrivileged()
        let rec = recommendation("system.admin.caches", admin: true, paths: paths)
        let result = await cleaner(files, privileged: privileged).perform(rec, selected: rec.items)
        #expect(privileged.calls.count == 1, "a single authentication prompt")
        #expect(privileged.calls[0] == [["/bin/rm", "-rf", "--"] + paths])
        #expect(privileged.prompts[0].contains("3"))
        #expect(result.usedAdmin && result.freed == 6000 && result.removedCount == 3 && result.failures.isEmpty)
    }

    @Test func cancellingThePasswordPromptKeepsEverythingAndSaysSo() async {
        let paths = ["/Library/Caches/com.a"]
        let files = FakeFiles(existing: paths)
        files.failures[paths[0]] = permissionDenied()
        let privileged = FakePrivileged()
        privileged.error = .cancelled
        let rec = recommendation("system.admin.caches", admin: true, paths: paths)
        let result = await cleaner(files, privileged: privileged).perform(rec, selected: rec.items)
        #expect(result.cancelled && result.freed == 0 && files.exists(paths[0]))
        #expect(result.failures.first?.reason == "Autorização cancelada.")
    }

    @Test func routinesAndBackgroundCallersCanForbidEscalation() async {
        let paths = ["/Library/Caches/com.a"]
        let files = FakeFiles(existing: paths)
        files.failures[paths[0]] = permissionDenied()
        let privileged = FakePrivileged()
        let rec = recommendation("system.admin.caches", admin: true, paths: paths)
        let result = await cleaner(files, privileged: privileged).perform(rec, selected: rec.items, allowAdmin: false)
        #expect(privileged.calls.isEmpty && result.failures.count == 1)
    }

    @Test func systemItemsIgnoreForceTrashBecauseTheyCannotGoThere() async {
        let paths = ["/Library/Caches/com.a"]
        let files = FakeFiles(existing: paths)
        let rec = recommendation("system.admin.caches", admin: true, paths: paths)
        _ = await cleaner(files).perform(rec, selected: rec.items, forceTrash: true)
        #expect(files.trashed.isEmpty && files.removed == paths)
    }

    @Test func manualTrashRefusesProtectedAndKeepsTheRest() async {
        let files = FakeFiles(existing: [home + "/Movies/a.mov", home + "/Documents"])
        let result = await cleaner(files).trashManually([
            CleanupItem(path: home + "/Movies/a.mov", size: 50), CleanupItem(path: home + "/Documents", size: 9),
        ])
        #expect(files.trashed == [home + "/Movies/a.mov"] && result.trashed == 50)
        #expect(result.failures.map(\.path) == [home + "/Documents"])
    }

    @Test func vanishedItemsAreSkippedSilently() async {
        let files = FakeFiles(existing: [])
        let rec = recommendation(paths: [home + "/Library/Caches/gone"])
        let result = await cleaner(files).perform(rec, selected: rec.items)
        #expect(result.removedCount == 0 && result.failures.isEmpty && result.freed == 0)
    }

    // MARK: Commands

    @Test func commandRecommendationsRunTheToolAndMeasureFreedSpace() async {
        let commands = FakeCommands(installed: ["docker"])
        let spec = CommandSpec(tool: "docker", args: ["system", "prune", "-f"])
        let rec = recommendation("virt.docker", command: spec, paths: [home + "/Library/Containers/com.docker.docker"])
        let readings = LockedBox<[Int64]>([1_000, 9_000])
        let c = cleaner(FakeFiles(existing: []), commands: commands) {
            var reading: Int64 = 0
            readings.update { reading = $0.isEmpty ? 0 : $0.removeFirst() }
            return reading
        }
        let result = await c.perform(rec, selected: rec.items)
        #expect(
            commands.runs.count == 1 && commands.runs[0].0 == "/usr/bin/docker"
                && commands.runs[0].1 == ["system", "prune", "-f"])
        #expect(result.freed == 8_000 && result.failures.isEmpty)
    }

    @Test func missingToolIsAFriendlyFailureNotACrash() async {
        let rec = recommendation("virt.docker", command: CommandSpec(tool: "docker", args: []), paths: [home + "/x"])
        let result = await cleaner(FakeFiles(existing: [])).perform(rec, selected: rec.items)
        #expect(result.failures.first?.reason == "“docker” não está instalado.")
    }

    @Test func failingCommandSurfacesItsOutput() async {
        let commands = FakeCommands(installed: ["docker"])
        commands.results = [CommandResult(status: 1, output: "Cannot connect to the Docker daemon\n")]
        let rec = recommendation(
            "virt.docker", command: CommandSpec(tool: "docker", args: ["system", "prune", "-f"]), paths: [home + "/x"])
        let result = await cleaner(FakeFiles(existing: []), commands: commands).perform(rec, selected: rec.items)
        #expect(result.failures.first?.reason == "Cannot connect to the Docker daemon")
        #expect(result.removedCount == 0)
    }

    @Test func snapshotsRunOncePerSelectedDateAsAdministrator() async {
        let rec = TimeMachineSnapshots.recommendation(dates: [
            "2026-11-07-101010", "2026-11-08-121212", "2026-11-09-090909",
        ])!
        let privileged = FakePrivileged()
        let commands = FakeCommands(installed: ["tmutil"])
        let selected = rec.items.filter { $0.argument != "2026-11-08-121212" }
        let result = await cleaner(FakeFiles(existing: []), privileged: privileged, commands: commands).perform(
            rec, selected: selected)
        #expect(privileged.calls.count == 1)
        #expect(
            privileged.calls[0] == [
                ["/usr/bin/tmutil", "deletelocalsnapshots", "2026-11-07-101010"],
                ["/usr/bin/tmutil", "deletelocalsnapshots", "2026-11-09-090909"],
            ])
        #expect(commands.runs.isEmpty, "never run unprivileged")
        #expect(result.usedAdmin && result.removedCount == 2)
    }

    @Test func snapshotCancelIsReported() async {
        let rec = TimeMachineSnapshots.recommendation(dates: ["2026-11-07-101010"])!
        let privileged = FakePrivileged()
        privileged.error = .cancelled
        let result = await cleaner(
            FakeFiles(existing: []), privileged: privileged, commands: FakeCommands(installed: ["tmutil"])
        ).perform(rec, selected: rec.items)
        #expect(result.cancelled && result.removedCount == 0)
    }

    @Test func snapshotParsingKeepsOnlyDates() {
        let out = "Snapshot dates for all disks:\n2026-11-07-101010\n2026-11-08-121212\n\ngarbage\n"
        #expect(TimeMachineSnapshots.parse(out) == ["2026-11-07-101010", "2026-11-08-121212"])
        #expect(TimeMachineSnapshots.recommendation(dates: []) == nil)
    }

    // MARK: Real filesystem

    @Test func realDeletionRemovesATreeInsideTheSandboxAndNothingElse() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        box.file("home/Library/Caches/com.x/deep/blob.bin", megabytes: 1)
        box.file("home/Library/Caches/com.keep/blob.bin", megabytes: 1, seed: 2)
        let guardrail = SafetyGuard(home: home)
        let real = Cleaner(guardrail: guardrail)
        let rec = recommendation(paths: [home + "/Library/Caches/com.x"])
        let result = await real.perform(rec, selected: rec.items)
        #expect(!FileManager.default.fileExists(atPath: home + "/Library/Caches/com.x"))
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Caches/com.keep/blob.bin"))
        #expect(result.removedCount == 1)
    }

    @Test func realDeletionOfADanglingSymlinkRemovesOnlyTheLink() async throws {
        let box = Sandbox()
        let home = box.dir("home")
        let target = box.file("outside/precious.bin", megabytes: 1)
        box.dir("home/Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/Caches/link", withDestinationPath: target)
        let rec = recommendation(paths: [home + "/Library/Caches/link"])
        _ = await Cleaner(guardrail: SafetyGuard(home: home)).perform(rec, selected: rec.items)
        #expect(FileManager.default.fileExists(atPath: target), "the target of a symlink is never touched")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home + "/Library/Caches/link")) == nil)
    }
}
