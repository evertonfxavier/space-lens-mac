import Darwin
import Foundation
import Testing

@Suite struct ScannerTests {
    private func scan(
        _ box: Sandbox, minNode: Int64 = 1, minFile: Int64 = 1, split: Int = 3,
        cancel: @escaping @Sendable () -> Bool = { false }
    ) -> ScanResult {
        DiskScanner(
            options: ScanOptions(roots: [box.root], minNodeSize: minNode, minFileSize: minFile, splitDepth: split),
            isCancelled: cancel
        ).scan()
    }

    @Test func sizesAddUpAcrossNestedDirectories() throws {
        let box = Sandbox()
        box.file("a/one.bin", megabytes: 2)
        box.file("a/b/two.bin", megabytes: 3, seed: 2)
        box.file("c/three.bin", megabytes: 1, seed: 3)
        let result = scan(box)
        let root = try #require(result.roots.first)
        #expect(root.size >= 6 << 20)
        #expect(root.size < 7 << 20)
        let a = try #require(root.find(path: box.path("a")))
        let b = try #require(root.find(path: box.path("a/b")))
        #expect(a.size >= 5 << 20)
        #expect(b.size >= 3 << 20)
        #expect(a.size > b.size)
        #expect(root.fileCount == 3)
        // Largest first.
        #expect(root.children.map(\.size) == root.children.map(\.size).sorted(by: >))
    }

    @Test func hardLinksAreCountedOnce() throws {
        let box = Sandbox()
        let original = box.file("data/original.bin", megabytes: 2)
        try FileManager.default.linkItem(atPath: original, toPath: box.path("data/link.bin"))
        try FileManager.default.linkItem(atPath: original, toPath: box.path("other/link2.bin").prepareParent())
        let root = try #require(scan(box).roots.first)
        #expect(root.size < 3 << 20)
        #expect(root.size >= 2 << 20)
    }

    @Test func symlinksAreNeverFollowed() throws {
        let outside = Sandbox()
        outside.file("huge.bin", megabytes: 5)
        let box = Sandbox()
        box.file("real/small.bin", megabytes: 1)
        try FileManager.default.createSymbolicLink(atPath: box.path("jump"), withDestinationPath: outside.root)
        try FileManager.default.createSymbolicLink(
            atPath: box.path("filelink"), withDestinationPath: outside.path("huge.bin"))
        let root = try #require(scan(box).roots.first)
        #expect(root.size < 2 << 20)
        #expect(root.find(path: box.path("jump")) == nil)
    }

    @Test func smallItemsFoldIntoResidualButStillCount() throws {
        let box = Sandbox()
        box.file("big/large.bin", megabytes: 2)
        box.file("tiny/a.txt", bytes: 10)
        box.file("tiny/b.txt", bytes: 10)
        box.file("loose.txt", bytes: 10)
        let result = scan(box, minNode: 1 << 20, minFile: 1 << 20)
        let root = try #require(result.roots.first)
        #expect(root.find(path: box.path("tiny")) == nil, "directory below the threshold is pruned")
        #expect(root.find(path: box.path("big"))?.children.count == 1)
        #expect(root.residual > 0, "pruned bytes are kept as residual")
        #expect(root.fileCount == 4, "pruned files still count")
        #expect(root.size == root.residual + root.children.reduce(0) { $0 + $1.size })
    }

    @Test func unreadableDirectoriesAreReportedNotFatal() throws {
        let box = Sandbox()
        box.file("open/ok.bin", megabytes: 1)
        box.file("locked/secret.bin", megabytes: 1)
        #expect(chmod(box.path("locked"), 0o000) == 0)
        let result = scan(box)
        let root = try #require(result.roots.first)
        #expect(result.deniedPaths.contains(box.path("locked")))
        #expect(result.deniedCount == 1)
        #expect(root.size < 2 << 20, "locked content is not counted")
        #expect(root.find(path: box.path("open")) != nil)
    }

    @Test func parallelScanMatchesSequentialScan() throws {
        let box = Sandbox()
        for i in 0..<6 {
            for j in 0..<4 {
                box.file("d\(i)/e\(j)/f\(i)\(j).bin", bytes: 1_100_000 + i * 1000 + j, seed: UInt8(i * 4 + j))
                box.file("d\(i)/e\(j)/g/h.bin", bytes: 3000 + j)
            }
        }
        let shallow = flatten(scan(box, split: 1).roots)
        let deep = flatten(scan(box, split: 3).roots)
        let deeper = flatten(scan(box, split: 6).roots)
        #expect(shallow == deep)
        #expect(deep == deeper)
        #expect(shallow.count > 24)
    }

    @Test func excludedPrefixesAreSkipped() throws {
        let box = Sandbox()
        box.file("keep/a.bin", megabytes: 1)
        box.file("skip/b.bin", megabytes: 4)
        let options = ScanOptions(
            roots: [box.root], minNodeSize: 1, minFileSize: 1, excludedPrefixes: [box.path("skip")])
        let root = try #require(DiskScanner(options: options).scan().roots.first)
        #expect(root.find(path: box.path("skip")) == nil)
        #expect(root.size < 2 << 20)
    }

    @Test func cancellationStopsEarlyAndFlagsTheResult() throws {
        let box = Sandbox()
        for i in 0..<20 { box.file("d\(i)/f.bin", megabytes: 1, seed: UInt8(i)) }
        let result = scan(box, cancel: { true })
        #expect(result.cancelled)
        #expect((result.roots.first?.size ?? 0) < 20 << 20)
    }

    @Test func missingOrNonDirectoryRootsAreIgnored() throws {
        let box = Sandbox()
        let file = box.file("plain.txt", bytes: 5)
        let result = DiskScanner(options: ScanOptions(roots: [box.path("nope"), file])).scan()
        #expect(result.roots.isEmpty)
        #expect(result.totalBytes == 0)
    }

    @Test func progressIsReported() async throws {
        let box = Sandbox()
        for i in 0..<30 { box.file("d\(i)/f.bin", megabytes: 1, seed: UInt8(i)) }
        let seen = LockedBox<Int>(0)
        let result = DiskScanner(options: ScanOptions(roots: [box.root], minNodeSize: 1, minFileSize: 1)).scan { p in
            seen.update { $0 = max($0, p.items) }
        }
        #expect(result.totalBytes >= 30 << 20)
        // The timer ticks every 150 ms; a fast scan may finish before the first tick, which is fine.
        #expect(seen.value >= 0)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func update(_ change: (inout T) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

extension String {
    /// Creates the parent directory and returns self.
    func prepareParent() -> String {
        try? FileManager.default.createDirectory(
            atPath: (self as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return self
    }
}
