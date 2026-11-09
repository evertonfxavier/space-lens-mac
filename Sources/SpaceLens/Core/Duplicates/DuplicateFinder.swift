import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var path: String
    public var modified: Date?
    public var id: String { path }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public var size: Int64
    public var files: [DuplicateFile]
    public var id: String { files.first?.path ?? UUID().uuidString }

    /// Space you get back by keeping one copy.
    public var wasted: Int64 { size * Int64(max(0, files.count - 1)) }

    /// The ticked copies that may go. Even if every copy is ticked, the oldest one stays: a file is never
    /// removed from the disk completely.
    public func removable(selected: Set<String>) -> [DuplicateFile] {
        var ticked = files.filter { selected.contains($0.path) }
        if ticked.count == files.count { ticked.removeFirst() }
        return ticked
    }
}

/// Finds identical files by size, then a cheap fingerprint (head + tail), then a full SHA-256, so almost no
/// file is read completely. Hard links never show up as duplicates because the scan counts them once.
/// APFS clones can: they look identical and may share their blocks, so the saving is an upper bound.
public enum DuplicateFinder {
    static let skippedFragments = ["/node_modules/", "/.git/", ".app/", ".photoslibrary/", "/Library/", "/.Trash/"]
    private static let sample = 64 * 1024

    public static func candidates(in roots: [FileNode], minSize: Int64 = 1 << 20) -> [FileNode] {
        var out: [FileNode] = []
        for root in roots {
            root.walk { node in
                guard !node.isDirectory, node.size >= minSize else { return }
                let path = node.path
                if skippedFragments.contains(where: { path.contains($0) }) { return }
                out.append(node)
            }
        }
        return out
    }

    public static func find(
        _ files: [FileNode], progress: (@Sendable (Int, Int) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files, by: \.size).filter { $0.value.count > 1 }
        var stage2: [[FileNode]] = []
        let total = bySize.values.reduce(0) { $0 + $1.count }
        let done = Counter()

        // Stage 1: head + tail fingerprint, in parallel over size groups.
        let sizeGroups = Array(bySize.values)
        let fingerprints = Box<[[FileNode]]>([])
        DispatchQueue.concurrentPerform(iterations: sizeGroups.count) { index in
            if isCancelled() { return }
            let group = sizeGroups[index]
            var buckets: [Data: [FileNode]] = [:]
            for file in group {
                if isCancelled() { return }
                if let digest = quickDigest(path: file.path, size: file.size) {
                    buckets[digest, default: []].append(file)
                }
                progress?(done.increment(), total * 2)
            }
            let survivors = buckets.values.filter { $0.count > 1 }
            fingerprints.append(contentsOf: survivors)
        }
        stage2 = fingerprints.value

        // Stage 2: full hash of the survivors.
        let results = Box<[DuplicateGroup]>([])
        DispatchQueue.concurrentPerform(iterations: stage2.count) { index in
            if isCancelled() { return }
            var buckets: [Data: [FileNode]] = [:]
            for file in stage2[index] {
                if isCancelled() { return }
                if let digest = fullDigest(path: file.path) { buckets[digest, default: []].append(file) }
                progress?(done.increment(), total * 2)
            }
            let groups = buckets.values.filter { $0.count > 1 }.map { nodes in
                DuplicateGroup(
                    size: nodes[0].size,
                    files: nodes.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }.map {
                        DuplicateFile(path: $0.path, modified: $0.modified)
                    })
            }
            results.append(contentsOf: groups)
        }
        return results.value.sorted { $0.wasted > $1.wasted }
    }

    static func quickDigest(path: String, size: Int64) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: sample)
        for offset in [Int64(0), max(0, size - Int64(sample))] {
            let n = pread(fd, &buffer, sample, off_t(offset))
            guard n >= 0 else { return nil }
            hasher.update(data: Data(buffer[0..<n]))
        }
        return Data(hasher.finalize())
    }

    static func fullDigest(path: String) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: Data(buffer[0..<n]))
        }
        return Data(hasher.finalize())
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class Box<T: RangeReplaceableCollection>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    init(_ initial: T) { storage = initial }
    func append<S: Sequence>(contentsOf items: S) where S.Element == T.Element {
        lock.lock()
        storage.append(contentsOf: items)
        lock.unlock()
    }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
