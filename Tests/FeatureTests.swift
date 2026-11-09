import Foundation
import Testing

// MARK: - Treemap

@Suite struct TreemapTests {
    private func overlap(_ a: TreemapRect, _ b: TreemapRect) -> Double {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    @Test func cellsTileTheBoundsExactly() {
        let bounds = TreemapRect(x: 10, y: 20, width: 400, height: 250)
        let items = (1...23).map { (id: $0, weight: Double($0 * $0)) }
        let cells = Treemap.layout(items, in: bounds)
        #expect(cells.count == 23)
        #expect(abs(cells.reduce(0) { $0 + $1.rect.area } - bounds.area) < 1e-6)
        for cell in cells {
            #expect(cell.rect.x >= bounds.x - 1e-9 && cell.rect.y >= bounds.y - 1e-9)
            #expect(cell.rect.x + cell.rect.width <= bounds.x + bounds.width + 1e-9)
            #expect(cell.rect.y + cell.rect.height <= bounds.y + bounds.height + 1e-9)
        }
        for i in 0..<cells.count {
            for j in (i + 1)..<cells.count { #expect(overlap(cells[i].rect, cells[j].rect) < 1e-6) }
        }
    }

    @Test func areaIsProportionalToWeight() {
        let bounds = TreemapRect(x: 0, y: 0, width: 300, height: 200)
        let items = [(id: "a", weight: 600.0), (id: "b", weight: 300.0), (id: "c", weight: 100.0)]
        let cells = Dictionary(uniqueKeysWithValues: Treemap.layout(items, in: bounds).map { ($0.id, $0.rect.area) })
        #expect(abs(cells["a"]! / bounds.area - 0.6) < 1e-9)
        #expect(abs(cells["b"]! / bounds.area - 0.3) < 1e-9)
        #expect(abs(cells["c"]! / bounds.area - 0.1) < 1e-9)
    }

    @Test func cellsStayReasonablySquare() {
        let items = (1...30).map { (id: $0, weight: Double(31 - $0)) }
        let cells = Treemap.layout(items, in: TreemapRect(x: 0, y: 0, width: 600, height: 400))
        let worst = cells.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        #expect(worst < 4, "squarified layout avoids slivers, worst aspect ratio was \(worst)")
    }

    @Test func degenerateInputs() {
        let bounds = TreemapRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Treemap.layout([(id: 1, weight: 0.0), (id: 2, weight: -5.0)], in: bounds).isEmpty)
        #expect(Treemap.layout([(id: 1, weight: 1.0)], in: TreemapRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
        let single = Treemap.layout([(id: 1, weight: 9.0)], in: bounds)
        #expect(single.count == 1 && single[0].rect == bounds)
        let skipped = Treemap.layout([(id: 1, weight: 3.0), (id: 2, weight: 0.0)], in: bounds)
        #expect(skipped.map(\.id) == [1])
    }
}

// MARK: - Duplicates

@Suite struct DuplicateTests {
    private func nodes(_ box: Sandbox) -> [FileNode] {
        let result = DiskScanner(options: ScanOptions(roots: [box.root], minNodeSize: 1, minFileSize: 1)).scan()
        return DuplicateFinder.candidates(in: result.roots, minSize: 1)
    }

    @Test func findsIdenticalFilesAndIgnoresLookalikes() throws {
        let box = Sandbox()
        box.file("a/photo.bin", megabytes: 2, seed: 7)
        box.file("b/photo-copy.bin", megabytes: 2, seed: 7)
        box.file("c/third.bin", megabytes: 2, seed: 7)
        // Same size, same first and last 64 KB, different in the middle: only the full hash can tell.
        let twin = box.file("d/twin.bin", megabytes: 2, seed: 7)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: twin))
        try handle.seek(toOffset: 1_000_000)
        try handle.write(contentsOf: Data([9, 9, 9, 9]))
        try handle.close()
        box.file("e/same-size-other.bin", megabytes: 2, seed: 8)
        box.file("f/unique-size.bin", bytes: 1_500_000, seed: 7)

        let groups = DuplicateFinder.find(nodes(box))
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(
            Set(group.files.map { ($0.path as NSString).lastPathComponent }) == [
                "photo.bin", "photo-copy.bin", "third.bin",
            ])
        #expect(group.wasted == group.size * 2)
    }

    @Test func hardLinksAreNotDuplicates() throws {
        let box = Sandbox()
        let original = box.file("a/x.bin", megabytes: 2, seed: 3)
        try FileManager.default.linkItem(atPath: original, toPath: box.path("b/y.bin").prepareParent())
        #expect(DuplicateFinder.find(nodes(box)).isEmpty)
    }

    @Test func oldestCopyComesFirstSoItIsTheOneToKeep() throws {
        let box = Sandbox()
        box.file("new.bin", megabytes: 1, seed: 5)
        box.file("old.bin", megabytes: 1, seed: 5)
        box.age("old.bin", days: 100)
        let group = try #require(DuplicateFinder.find(nodes(box)).first)
        #expect((group.files[0].path as NSString).lastPathComponent == "old.bin")
    }

    @Test func appBundlesAndDependenciesAreNotCandidates() {
        let box = Sandbox()
        box.file("Foo.app/Contents/lib.bin", megabytes: 2, seed: 1)
        box.file("p/node_modules/x/lib.bin", megabytes: 2, seed: 1)
        box.file("p/.git/objects/pack.bin", megabytes: 2, seed: 1)
        box.file("ok/lib.bin", megabytes: 2, seed: 1)
        let found = nodes(box).map(\.path)
        #expect(found == [box.path("ok/lib.bin")])
    }

    @Test func cancellationReturnsWithoutHanging() {
        let box = Sandbox()
        for i in 0..<6 { box.file("f\(i).bin", megabytes: 1, seed: 1) }
        #expect(DuplicateFinder.find(nodes(box), isCancelled: { true }).isEmpty)
    }
}

// MARK: - Schedules and routines

@Suite struct ScheduleTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func dailyPicksTodayIfStillAheadElseTomorrow() {
        let s = Schedule.daily(hour: 12, minute: 30)
        #expect(s.next(after: date(2026, 11, 9, 8), calendar: calendar) == date(2026, 11, 9, 12, 30))
        #expect(s.next(after: date(2026, 11, 9, 12, 30), calendar: calendar) == date(2026, 11, 10, 12, 30))
        #expect(s.next(after: date(2026, 11, 9, 20), calendar: calendar) == date(2026, 11, 10, 12, 30))
    }

    @Test func weeklyAndMonthly() {
        // 2026-11-09 is a Monday (weekday 2). Sunday is 1.
        #expect(
            Schedule.weekly(weekday: 1, hour: 10, minute: 0).next(after: date(2026, 11, 9, 9), calendar: calendar)
                == date(2026, 11, 15, 10))
        #expect(
            Schedule.weekly(weekday: 2, hour: 10, minute: 0).next(after: date(2026, 11, 9, 9), calendar: calendar)
                == date(2026, 11, 9, 10))
        #expect(
            Schedule.monthly(day: 15, hour: 3, minute: 0).next(after: date(2026, 11, 16), calendar: calendar)
                == date(2026, 12, 15, 3))
        #expect(
            Schedule.monthly(day: 31, hour: 3, minute: 0).next(after: date(2026, 1, 29), calendar: calendar)
                == date(2026, 2, 28, 3), "day is clamped to 28")
    }

    @Test func everyHoursIsRelativeToTheLastRun() {
        #expect(Schedule.everyHours(6).next(after: date(2026, 11, 9, 8)) == date(2026, 11, 9, 14))
        #expect(Schedule.everyHours(0).next(after: date(2026, 11, 9, 8)) == date(2026, 11, 9, 9), "never zero")
    }

    @Test func dueLogicCatchesUpOnceAndSkipsDisabled() {
        let created = date(2026, 11, 1, 9)
        var routine = Routine(
            name: "r", schedule: .daily(hour: 12, minute: 0), task: .emptyTrash(olderThanDays: 30), createdAt: created)
        #expect(!routine.isDue(at: date(2026, 11, 1, 11), calendar: calendar))
        #expect(routine.isDue(at: date(2026, 11, 1, 12, 1), calendar: calendar))
        // Mac was off for a week: one catch-up run, then back to the normal rhythm.
        #expect(routine.isDue(at: date(2026, 11, 9, 8), calendar: calendar))
        routine.lastRun = date(2026, 11, 9, 8)
        #expect(!routine.isDue(at: date(2026, 11, 9, 11), calendar: calendar))
        #expect(routine.isDue(at: date(2026, 11, 9, 12), calendar: calendar))
        routine.enabled = false
        #expect(!routine.isDue(at: date(2027, 1, 1), calendar: calendar))
    }

    @Test func routinesSurviveJSONRoundTrip() throws {
        let routines: [Routine] = [
            Routine(name: "a", schedule: .weekly(weekday: 3, hour: 4, minute: 5), task: .cleanCaches(minAgeDays: 7)),
            Routine(
                name: "b", schedule: .everyHours(2),
                task: .cleanProjectArtifacts(roots: ["/x", "/y"], inactiveDays: 60), apply: true),
            Routine(name: "c", schedule: .monthly(day: 1, hour: 0, minute: 0), task: .lowSpaceAlert(thresholdGB: 15)),
            Routine(
                name: "d", schedule: .daily(hour: 1, minute: 2),
                task: .cleanDownloads(olderThanDays: 30, installersOnly: true)),
        ]
        let data = try JSONEncoder().encode(routines)
        #expect(try JSONDecoder().decode([Routine].self, from: data) == routines)
    }

    @Test func presetsAreSafeByDefault() {
        let presets = Routine.presets(home: "/Users/me")
        #expect(presets.count == 4)
        for preset in presets {
            if case .cleanCaches = preset.task { continue }
            #expect(!preset.apply, "\(preset.name) only reports until you turn it on")
        }
    }
}

@Suite struct RoutineRunnerTests {
    final class Collector: Notifier, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [(String, String)] = []
        func notify(title: String, body: String) async {
            lock.withLock { messages.append((title, body)) }
        }
    }

    /// Real deletes inside the sandbox; "Trash" is a folder in the sandbox.
    struct SandboxFiles: FileOperations {
        let trashDir: String
        func trash(_ path: String) throws {
            try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: trashDir + "/" + UUID().uuidString)
        }
        func remove(_ path: String) throws { try FileManager.default.removeItem(atPath: path) }
        func exists(_ path: String) -> Bool { SystemFileOperations().exists(path) }
    }

    private func make(
        _ box: Sandbox, disk: @escaping @Sendable () -> DiskUsage? = { nil }
    ) -> (RoutineRunner, Collector, String) {
        let home = box.dir("home")
        let cleaner = Cleaner(
            guardrail: SafetyGuard(home: home), files: SandboxFiles(trashDir: box.path("fake-trash")),
            privileged: FakePrivileged(), commands: FakeCommands(), freeBytes: { 0 })
        let notifier = Collector()
        return (
            RoutineRunner(home: home, cleaner: cleaner, notifier: notifier, disk: disk, minNodeSize: 1 << 20), notifier,
            home
        )
    }

    @Test func cacheRoutineRemovesOnlyOldSafeCaches() async {
        let box = Sandbox()
        let (runner, notifier, home) = make(box)
        box.file("home/Library/Caches/com.old/blob.bin", megabytes: 2)
        box.file("home/Library/Caches/com.new/blob.bin", megabytes: 2, seed: 2)
        box.file("home/Library/Caches/com.apple.Safari/blob.bin", megabytes: 2, seed: 3)
        box.file("home/Documents/keep.bin", megabytes: 2, seed: 4)
        box.age("home/Library/Caches/com.old", days: 40)
        box.age("home/Library/Caches/com.apple.Safari", days: 40)
        let routine = Routine(
            name: "Caches", schedule: .daily(hour: 1, minute: 0), task: .cleanCaches(minAgeDays: 7), apply: true)
        let record = await runner.run(routine)
        #expect(!FileManager.default.fileExists(atPath: home + "/Library/Caches/com.old"))
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Caches/com.new"), "recent cache stays")
        #expect(
            FileManager.default.fileExists(atPath: home + "/Library/Caches/com.apple.Safari"),
            "review-level cache is never touched unattended")
        #expect(FileManager.default.fileExists(atPath: home + "/Documents/keep.bin"))
        #expect(record.applied && record.freed >= 2 << 20 && record.itemCount == 1 && !record.failed)
        #expect(notifier.messages.count == 1)
    }

    @Test func cacheRoutineLeavesDeveloperCachesAndTheTrashAlone() async {
        let box = Sandbox()
        let (runner, _, home) = make(box)
        box.file("home/Library/Developer/Xcode/DerivedData/Proj/out.o", megabytes: 2)
        box.file("home/.npm/_cacache/content.bin", megabytes: 2, seed: 2)
        box.file("home/.Trash/old.zip", megabytes: 2, seed: 3)
        box.file("home/Library/Caches/com.old/blob.bin", megabytes: 2, seed: 4)
        for path in [
            "home/Library/Developer/Xcode/DerivedData", "home/.npm/_cacache", "home/.Trash/old.zip",
            "home/Library/Caches/com.old",
        ] {
            box.age(path, days: 200)
        }
        let routine = Routine(
            name: "C", schedule: .daily(hour: 1, minute: 0), task: .cleanCaches(minAgeDays: 7), apply: true)
        let record = await runner.run(routine)
        #expect(!FileManager.default.fileExists(atPath: home + "/Library/Caches/com.old"))
        #expect(
            FileManager.default.fileExists(atPath: home + "/Library/Developer/Xcode/DerivedData"),
            "developer caches have their own routine")
        #expect(FileManager.default.fileExists(atPath: home + "/.npm/_cacache"))
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/old.zip"))
        #expect(record.itemCount == 1)
    }

    @Test func lookOnlyModeReportsPotentialAndTouchesNothing() async {
        let box = Sandbox()
        let (runner, notifier, home) = make(box)
        box.file("home/Library/Caches/com.old/blob.bin", megabytes: 2)
        box.age("home/Library/Caches/com.old", days: 40)
        let routine = Routine(
            name: "Look", schedule: .daily(hour: 1, minute: 0), task: .cleanCaches(minAgeDays: 7), apply: false)
        let record = await runner.run(routine)
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Caches/com.old"))
        #expect(!record.applied && record.freed == 0 && record.potential >= 2 << 20)
        #expect(notifier.messages.count == 1 && notifier.messages[0].1.contains("só avisar"))
    }

    @Test func nothingToCleanIsQuiet() async {
        let box = Sandbox()
        let (runner, notifier, _) = make(box)
        let routine = Routine(
            name: "Empty", schedule: .daily(hour: 1, minute: 0), task: .cleanCaches(minAgeDays: 7), apply: true)
        let record = await runner.run(routine)
        #expect(record.message == "Nada para limpar." && record.itemCount == 0 && notifier.messages.isEmpty)
    }

    @Test func downloadsRoutineMovesInstallersToTheTrashNotForGood() async {
        let box = Sandbox()
        let (runner, _, home) = make(box)
        box.file("home/Downloads/old.dmg", megabytes: 2)
        box.file("home/Downloads/new.dmg", megabytes: 2, seed: 2)
        box.file("home/Downloads/notes.pdf", megabytes: 2, seed: 3)
        box.age("home/Downloads/old.dmg", days: 60)
        box.age("home/Downloads/notes.pdf", days: 60)
        let routine = Routine(
            name: "DL", schedule: .daily(hour: 1, minute: 0),
            task: .cleanDownloads(olderThanDays: 30, installersOnly: true), apply: true)
        let record = await runner.run(routine)
        #expect(!FileManager.default.fileExists(atPath: home + "/Downloads/old.dmg"))
        #expect(FileManager.default.fileExists(atPath: home + "/Downloads/new.dmg"))
        #expect(
            FileManager.default.fileExists(atPath: home + "/Downloads/notes.pdf"),
            "installersOnly leaves documents alone")
        #expect(record.trashed >= 2 << 20 && record.freed == 0)
        #expect(FileManager.default.fileExists(atPath: box.path("fake-trash")))
    }

    @Test func projectRoutineSkipsActiveProjects() async {
        let box = Sandbox()
        let (runner, _, home) = make(box)
        box.file("home/Projects/stale/package.json", bytes: 10)
        box.file("home/Projects/stale/node_modules/a/i.js", megabytes: 2)
        box.file("home/Projects/active/package.json", bytes: 10)
        box.file("home/Projects/active/node_modules/a/i.js", megabytes: 2, seed: 2)
        box.age("home/Projects/stale/node_modules", days: 120)
        let routine = Routine(
            name: "P", schedule: .daily(hour: 1, minute: 0),
            task: .cleanProjectArtifacts(roots: [home + "/Projects"], inactiveDays: 60), apply: true)
        let record = await runner.run(routine)
        #expect(!FileManager.default.fileExists(atPath: home + "/Projects/stale/node_modules"))
        #expect(FileManager.default.fileExists(atPath: home + "/Projects/active/node_modules"))
        #expect(FileManager.default.fileExists(atPath: home + "/Projects/stale/package.json"))
        #expect(record.freed >= 2 << 20)
    }

    @Test func emptyTrashRoutineRespectsAge() async {
        let box = Sandbox()
        let (runner, _, home) = make(box)
        box.file("home/.Trash/just-deleted.bin", megabytes: 2)
        let thirty = Routine(
            name: "T", schedule: .daily(hour: 1, minute: 0), task: .emptyTrash(olderThanDays: 30), apply: true)
        let kept = await runner.run(thirty)
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/just-deleted.bin"))
        #expect(kept.itemCount == 0)
        let now = Routine(
            name: "T0", schedule: .daily(hour: 1, minute: 0), task: .emptyTrash(olderThanDays: 0), apply: true)
        let emptied = await runner.run(now)
        #expect(!FileManager.default.fileExists(atPath: home + "/.Trash/just-deleted.bin"))
        #expect(emptied.freed >= 2 << 20)
    }

    @Test func lowSpaceAlertFiresOnlyBelowTheThreshold() async {
        let low = DiskUsage(total: 500 << 30, availableImportant: 5 << 30, availableRaw: 5 << 30)
        let high = DiskUsage(total: 500 << 30, availableImportant: 200 << 30, availableRaw: 200 << 30)
        let box1 = Sandbox()
        let (lowRunner, lowNotifier, _) = make(box1, disk: { low })
        box1.file("home/Library/Caches/com.old/blob.bin", megabytes: 2)
        let routine = Routine(name: "Low", schedule: .everyHours(6), task: .lowSpaceAlert(thresholdGB: 20))
        let alert = await lowRunner.run(routine)
        #expect(alert.message.hasPrefix("Restam") && alert.potential >= 2 << 20)
        #expect(lowNotifier.messages.count == 1)

        let box2 = Sandbox()
        let (highRunner, highNotifier, _) = make(box2, disk: { high })
        let ok = await highRunner.run(routine)
        #expect(ok.message.hasPrefix("Espaço livre ok") && highNotifier.messages.isEmpty)
    }

    @Test func routineWithNotificationsOffStaysSilent() async {
        let box = Sandbox()
        let low = DiskUsage(total: 500 << 30, availableImportant: 1 << 30, availableRaw: 1 << 30)
        let (runner, notifier, _) = make(box, disk: { low })
        var routine = Routine(name: "Low", schedule: .everyHours(6), task: .lowSpaceAlert(thresholdGB: 20))
        routine.notify = false
        _ = await runner.run(routine)
        #expect(notifier.messages.isEmpty)
    }
}

// MARK: - Persistence and system

@Suite struct PersistenceTests {
    @Test func jsonStoreRoundTripsAndSurvivesCorruption() throws {
        let box = Sandbox()
        let store = JSONStore<[RunRecord]>(url: URL(fileURLWithPath: box.path("deep/er/history.json")))
        #expect(store.load(default: []).isEmpty)
        let record = RunRecord(
            routineID: UUID(), routineName: "r", date: Date(timeIntervalSince1970: 1_700_000_000), applied: true,
            freed: 5, message: "ok")
        #expect(store.save([record]))
        #expect(store.load(default: []) == [record])
        try "{ not json".write(toFile: box.path("deep/er/history.json"), atomically: true, encoding: .utf8)
        #expect(store.load(default: []).isEmpty, "a corrupt file never crashes the app")
    }

    @Test func settingsFromAnOlderFileKeepNewDefaults() throws {
        let old = #"{"scope":"wholeDisk","autoScanHours":6}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.scope == .wholeDisk && settings.autoScanHours == 6)
        #expect(settings.requireAuthToClean && settings.showFreeSpaceInMenuBar && settings.lowSpaceThresholdGB == 20)
    }

    @Test func summaryListsOnlyWhatIsSafeAndFreeable() throws {
        let box = Sandbox()
        let home = box.dir("home")
        box.file("home/Library/Caches/com.foo/blob.bin", megabytes: 3)
        box.file("home/Downloads/x.dmg", megabytes: 3, seed: 2)
        let result = DiskScanner(options: ScanOptions(roots: [home])).scan()
        let analysis = Analyzer(home: home).analyze(result.roots)
        let summary = ScanSummary(result: result, analysis: analysis, scope: .home)
        #expect(summary.top.map(\.id) == ["caches.user"])
        #expect(summary.safeFreeable == analysis.safeFreeable)
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(ScanSummary.self, from: data) == summary)
    }

    @Test func diskInfoIsConsistent() throws {
        let usage = try #require(DiskInfo.current())
        #expect(usage.total > 0)
        #expect(usage.used + usage.availableImportant == usage.total || usage.used == 0)
        #expect(usage.usedFraction >= 0 && usage.usedFraction <= 1)
        #expect(usage.purgeable >= 0)
    }

    @Test func byteFormatNeverGoesNegative() {
        #expect(ByteFormat.string(-5) == ByteFormat.string(0))
        #expect(ByteFormat.string(1_500_000_000).contains("GB"))
    }

    @Test func commandResolutionFindsRealToolsAndRejectsFakeOnes() async {
        let runner = ProcessCommandRunner()
        #expect(runner.resolve("ls") == "/bin/ls")
        #expect(runner.resolve("definitely-not-a-tool-xyz") == nil)
        let ok = await runner.run(executable: "/bin/echo", args: ["hello"])
        #expect(ok.status == 0 && ok.output == "hello\n")
        let bad = await runner.run(executable: "/usr/bin/false", args: [])
        #expect(bad.status != 0)
    }
}

@Suite struct DuplicateSelectionTests {
    private func group() -> DuplicateGroup {
        DuplicateGroup(size: 10, files: ["/a", "/b", "/c"].map { DuplicateFile(path: $0, modified: nil) })
    }

    @Test func tickedCopiesGoAndUntickedOnesStay() {
        #expect(group().removable(selected: ["/b", "/c"]).map(\.path) == ["/b", "/c"])
        #expect(group().removable(selected: ["/c"]).map(\.path) == ["/c"])
        #expect(group().removable(selected: []).isEmpty)
    }

    @Test func tickingEveryCopyStillKeepsTheOldest() {
        #expect(group().removable(selected: ["/a", "/b", "/c"]).map(\.path) == ["/b", "/c"])
    }

    @Test func pathsOutsideTheGroupAreIgnored() {
        #expect(group().removable(selected: ["/zzz", "/b"]).map(\.path) == ["/b"])
    }
}
