import Foundation
import Testing

@Suite struct AnalyzerTests {
    /// A believable home: caches, a node project, downloads, trash, photos, documents.
    private func makeHome() -> (Sandbox, String) {
        let box = Sandbox()
        let home = box.dir("home")
        box.file("home/Library/Caches/com.foo.app/blob.bin", megabytes: 3)
        box.file("home/Library/Caches/com.apple.Safari/blob.bin", megabytes: 2, seed: 2)
        box.file("home/Library/Logs/app.log", megabytes: 1, seed: 3)
        box.file("home/Library/Application Support/Slack/data.db", megabytes: 2, seed: 4)
        box.file("home/Library/Developer/Xcode/DerivedData/Proj-abc/Build/out.o", megabytes: 4, seed: 5)
        box.file("home/Projects/webapp/package.json", bytes: 20)
        box.file("home/Projects/webapp/node_modules/lib/index.js", megabytes: 5, seed: 6)
        box.file("home/Projects/webapp/src/main.ts", bytes: 100)
        box.file("home/Projects/notaproject/node_modules/lib/index.js", megabytes: 2, seed: 7)
        box.file("home/Projects/gradle-app/settings.gradle", bytes: 10)
        box.file("home/Projects/gradle-app/build/out.jar", megabytes: 2, seed: 8)
        box.file("home/Projects/plain/build/out.bin", megabytes: 2, seed: 9)
        box.file("home/Downloads/installer.dmg", megabytes: 3, seed: 10)
        box.file("home/Downloads/report.pdf", megabytes: 2, seed: 11)
        box.file("home/.Trash/old.zip", megabytes: 2, seed: 12)
        box.file("home/Pictures/Photos Library.photoslibrary/originals/a.heic", megabytes: 6, seed: 13)
        box.file("home/Documents/thesis.docx", megabytes: 2, seed: 14)
        box.file("home/Movies/film.mov", megabytes: 3, seed: 15)
        box.file("home/misc/stuff.bin", megabytes: 1, seed: 16)
        return (box, home)
    }

    private func analyze(_ home: String, now: Date = Date()) -> (ScanResult, Analysis, Analyzer) {
        let result = DiskScanner(options: ScanOptions(roots: [home])).scan()
        let analyzer = Analyzer(home: home, now: now)
        return (result, analyzer.analyze(result.roots), analyzer)
    }

    @Test func categoriesPartitionTheScanWithoutDoubleCounting() {
        let (box, home) = makeHome()
        _ = box
        let (result, analysis, _) = analyze(home)
        #expect(analysis.scannedBytes == result.totalBytes)
        #expect(analysis.categoryBytes[.caches, default: 0] >= 6 << 20)
        #expect(analysis.categoryBytes[.developer, default: 0] >= 4 << 20 + 5 << 20)
        #expect(analysis.categoryBytes[.trash, default: 0] >= 2 << 20)
        #expect(analysis.categoryBytes[.media, default: 0] >= 9 << 20)
        #expect(analysis.categoryBytes[.documents, default: 0] >= 2 << 20)
        #expect(analysis.categoryBytes[.appData, default: 0] >= 2 << 20)
    }

    @Test func userAndAppleCachesAreSeparatedBySafety() throws {
        let (box, home) = makeHome()
        _ = box
        let (_, analysis, _) = analyze(home)
        let user = try #require(analysis.recommendations.first { $0.id == "caches.user" })
        let apple = try #require(analysis.recommendations.first { $0.id == "caches.apple" })
        #expect(user.safety == .safe && user.preselect)
        #expect(apple.safety == .review && !apple.preselect)
        #expect(user.items.map(\.name) == ["com.foo.app"])
        #expect(apple.items.map(\.name) == ["com.apple.Safari"])
        #expect(user.mode == .delete)
    }

    @Test func artifactsNeedAProjectMarkerNextToThem() throws {
        let (box, home) = makeHome()
        _ = box
        let (_, analysis, _) = analyze(home)
        let node = try #require(analysis.recommendations.first { $0.id == "artifact.node" })
        #expect(node.items.map(\.path) == [home + "/Projects/webapp/node_modules"])
        #expect(node.items.first?.label == "webapp")
        let gradle = try #require(analysis.recommendations.first { $0.id == "artifact.gradle" })
        #expect(gradle.items.map(\.path) == [home + "/Projects/gradle-app/build"])
        let all = analysis.recommendations.flatMap(\.items).map(\.path)
        #expect(!all.contains(home + "/Projects/plain/build"), "build without a gradle file is not recognised")
        #expect(!all.contains(home + "/Projects/notaproject/node_modules"), "node_modules without package.json")
    }

    @Test func recentProjectsStartUntickedAndStaleOnesTicked() throws {
        let (box, home) = makeHome()
        let (_, fresh, _) = analyze(home)
        #expect(fresh.recommendations.first { $0.id == "artifact.node" }?.items.first?.preselected == false)
        box.age("home/Projects/webapp/node_modules", days: 90)
        let (_, stale, _) = analyze(home)
        #expect(stale.recommendations.first { $0.id == "artifact.node" }?.items.first?.preselected == true)
    }

    @Test func downloadsInstallersAreSeparatedAndGoToTheTrash() throws {
        let (box, home) = makeHome()
        _ = box
        let (_, analysis, _) = analyze(home)
        let installers = try #require(analysis.recommendations.first { $0.id == "downloads.installers" })
        #expect(installers.items.map(\.name) == ["installer.dmg"])
        #expect(installers.mode == .trash)
        #expect(installers.safety == .review)
        #expect(!analysis.recommendations.contains { $0.id == "downloads.old" }, "nothing is 90 days old yet")
    }

    @Test func oldDownloadsAppearOnlyAfterNinetyDays() throws {
        let (box, home) = makeHome()
        box.age("home/Downloads/report.pdf", days: 120)
        let (_, analysis, _) = analyze(home)
        let old = try #require(analysis.recommendations.first { $0.id == "downloads.old" })
        #expect(old.items.map(\.name) == ["report.pdf"])
    }

    @Test func trashAndPhotosAndDocumentsAreClassified() throws {
        let (box, home) = makeHome()
        _ = box
        let (result, analysis, analyzer) = analyze(home)
        let root = try #require(result.roots.first)
        let trash = try #require(analysis.recommendations.first { $0.id == "trash.items" })
        #expect(trash.safety == .safe)
        let photos = try #require(root.find(path: home + "/Pictures/Photos Library.photoslibrary"))
        #expect(analyzer.classify(photos).safety == .keep)
        #expect(!analysis.recommendations.flatMap(\.items).contains { $0.path.contains("photoslibrary") })
        let thesis = try #require(root.find(path: home + "/Documents/thesis.docx"))
        let cls = analyzer.classify(thesis)
        #expect(cls.category == .documents && cls.safety == .review)
        let stuff = try #require(root.find(path: home + "/misc/stuff.bin"))
        #expect(analyzer.classify(stuff) == .unknown)
    }

    @Test func classifyUsesTheNearestAncestorRule() throws {
        let (box, home) = makeHome()
        _ = box
        let (result, _, analyzer) = analyze(home)
        let root = try #require(result.roots.first)
        let deep = try #require(root.find(path: home + "/Projects/webapp/node_modules/lib/index.js"))
        let cls = analyzer.classify(deep)
        #expect(cls.safety == .safe && cls.category == .developer)
        let derived = try #require(root.find(path: home + "/Library/Developer/Xcode/DerivedData/Proj-abc"))
        #expect(analyzer.classify(derived).entryID == "dev.xcode.derived")
    }

    @Test func largeOldFilesAreFlaggedButNotRecentOrProtectedOnes() throws {
        let box = Sandbox()
        let home = box.dir("home")
        let big = 520 << 20
        box.file("home/Movies/old.mov", bytes: big, seed: 1)
        box.file("home/Movies/new.mov", bytes: big, seed: 2)
        box.file("home/Library/Mobile Documents/cloud.bin", bytes: big, seed: 3)
        box.age("home/Movies/old.mov", days: 400)
        box.age("home/Library/Mobile Documents/cloud.bin", days: 400)
        let (_, analysis, _) = analyze(home)
        let large = try #require(analysis.recommendations.first { $0.id == "large.old" })
        #expect(large.items.map(\.name) == ["old.mov"])
        #expect(large.mode == .trash && !large.preselect && large.items.allSatisfy { !$0.preselected })
    }

    @Test func recommendationsAreOrderedBySafetyThenSize() {
        let (box, home) = makeHome()
        _ = box
        let (_, analysis, _) = analyze(home)
        let keys = analysis.recommendations.map { ($0.safety.rawValue, -$0.totalSize) }
        #expect(keys.elementsEqual(keys.sorted { $0 < $1 }, by: { $0 == $1 }))
        #expect(analysis.safeFreeable > 0)
    }

    @Test func commandEntriesNeedTheirToolInstalled() throws {
        let box = Sandbox()
        let home = box.dir("home")
        box.file("home/Library/Containers/com.docker.docker/Data/vms/Docker.raw", megabytes: 105)
        let result = DiskScanner(options: ScanOptions(roots: [home])).scan()
        let withDocker = Analyzer(home: home, toolExists: { _ in true }).analyze(result.roots)
        let docker = try #require(withDocker.recommendations.first { $0.id == "virt.docker" })
        #expect(docker.command?.tool == "docker" && docker.sizeIsReference && !docker.preselect)
        #expect(withDocker.safeFreeable == 0, "reference sizes never count as safe-to-free")
        let without = Analyzer(home: home, toolExists: { _ in false }).analyze(result.roots)
        #expect(!without.recommendations.contains { $0.id == "virt.docker" })
        let tiny = Sandbox()
        let tinyHome = tiny.dir("home")
        tiny.file("home/Library/Containers/com.docker.docker/Data/vms/Docker.raw", megabytes: 5)
        let tinyScan = DiskScanner(options: ScanOptions(roots: [tinyHome])).scan()
        let small = Analyzer(home: tinyHome, toolExists: { _ in true }).analyze(tinyScan.roots)
        #expect(
            !small.recommendations.contains { $0.id == "virt.docker" }, "a nearly empty Docker is not worth a prompt")
    }

    @Test func catalogHasNoDuplicateIDsAndEveryActionableSafeEntryIsReachable() {
        let entries = Catalog.entries(home: "/Users/x")
        #expect(Set(entries.map(\.id)).count == entries.count)
        for entry in entries where entry.actionable {
            #expect(!entry.matches.isEmpty && !entry.explanation.isEmpty, "\(entry.id) needs a reason")
            if entry.safety != .safe { #expect(!entry.preselect, "\(entry.id): review items start unticked") }
            if entry.admin {
                #expect(entry.mode == .delete && !entry.preselect, "\(entry.id): system items are opt-in")
            }
        }
        for kind in Catalog.artifactKinds { #expect(Catalog.artifactGroups[kind.group] != nil) }
    }
}

@Suite struct TopItemsTests {
    @Test func topItemsListTheBiggestThingsPerCategoryLargestFirst() throws {
        let box = Sandbox()
        let home = box.dir("home")
        box.file("home/Library/Caches/com.small/a.bin", megabytes: 2)
        box.file("home/Library/Caches/com.big/a.bin", megabytes: 5, seed: 2)
        box.file("home/Documents/doc.bin", megabytes: 3, seed: 3)
        let result = DiskScanner(options: ScanOptions(roots: [home])).scan()
        let analysis = Analyzer(home: home).analyze(result.roots)
        let caches = try #require(analysis.topItems[.caches])
        #expect(caches.map(\.name) == ["com.big", "com.small"])
        #expect(caches.allSatisfy { $0.safety == .safe })
        #expect(analysis.topItems[.documents]?.map(\.name) == ["doc.bin"])
        #expect((analysis.topItems[.trash] ?? []).isEmpty)
    }
}
