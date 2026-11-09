import Darwin
import Foundation

public struct ScanOptions: Sendable {
    public var roots: [String]
    /// Directories below this size are folded into their parent's `residual`.
    public var minNodeSize: Int64
    /// Files below this size are folded into their directory's `residual`.
    public var minFileSize: Int64
    public var excludedPrefixes: [String]
    /// Directories this many levels below a root are scanned as independent parallel units.
    public var splitDepth: Int

    public init(
        roots: [String], minNodeSize: Int64 = 1 << 20, minFileSize: Int64 = 1 << 20,
        excludedPrefixes: [String] = [], splitDepth: Int = 3
    ) {
        self.roots = roots
        self.minNodeSize = minNodeSize
        self.minFileSize = minFileSize
        self.excludedPrefixes = excludedPrefixes
        self.splitDepth = max(1, splitDepth)
    }
}

public struct ScanProgress: Sendable {
    public var items: Int
    public var bytes: Int64
    public var currentPath: String
}

public struct ScanResult: @unchecked Sendable {
    public var roots: [FileNode]
    /// Directories macOS refused to open (needs Full Disk Access). Capped; see `deniedCount`.
    public var deniedPaths: [String]
    public var deniedCount: Int
    public var duration: TimeInterval
    public var cancelled: Bool
    public var finishedAt: Date

    public var totalBytes: Int64 { roots.reduce(0) { $0 + $1.size } }
}

/// Walks the disk with `readdir` + `fstatat` (no String per small file), in parallel below `splitDepth`.
/// Sizes are allocated bytes, hard links are counted once, symlinks are never followed and other
/// volumes are not entered.
public final class DiskScanner: @unchecked Sendable {
    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    private final class UnitCollector {
        struct Unit {
            let node: FileNode
            let dev: dev_t
        }
        let splitDepth: Int
        var units: [Unit] = []
        init(splitDepth: Int) { self.splitDepth = splitDepth }
    }

    private static let deniedCap = 500

    private let options: ScanOptions
    private let isCancelled: @Sendable () -> Bool
    private let lock = NSLock()
    private var seen = Set<InodeKey>()
    private var denied: [String] = []
    private var deniedCount = 0
    private var itemCount = 0
    private var byteCount: Int64 = 0
    private var currentPath = ""

    public init(options: ScanOptions, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.options = options
        self.isCancelled = isCancelled
    }

    public func scan(progress: (@Sendable (ScanProgress) -> Void)? = nil) -> ScanResult {
        let started = Date()
        var timer: DispatchSourceTimer?
        if let progress {
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            source.schedule(deadline: .now() + 0.1, repeating: 0.15)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let snapshot = ScanProgress(items: self.itemCount, bytes: self.byteCount, currentPath: self.currentPath)
                self.lock.unlock()
                progress(snapshot)
            }
            source.resume()
            timer = source
        }
        defer { timer?.cancel() }

        let collector = UnitCollector(splitDepth: options.splitDepth)
        var roots: [FileNode] = []
        for raw in options.roots {
            let path = Self.normalize(raw)
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let node = FileNode(
                name: path == "/" ? "/" : (path as NSString).lastPathComponent, path: path, isDirectory: true,
                modified: Self.date(st.st_mtimespec), changed: Self.date(st.st_ctimespec))
            roots.append(node)
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if fd < 0 {
                node.unreadable = true
                node.isFinalized = true
                recordDenied(path, errno: errno)
                continue
            }
            scanDirectory(fd: fd, path: path, node: node, dev: st.st_dev, depth: 0, collector: collector)
        }

        let units = collector.units
        DispatchQueue.concurrentPerform(iterations: units.count) { index in
            guard !isCancelled() else { return }
            let unit = units[index]
            let fd = open(unit.node.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                unit.node.unreadable = true
                unit.node.isFinalized = true
                recordDenied(unit.node.path, errno: errno)
                return
            }
            scanDirectory(fd: fd, path: unit.node.path, node: unit.node, dev: unit.dev, depth: 0, collector: nil)
        }

        for root in roots { finalizeTree(root) }

        lock.lock()
        let result = ScanResult(
            roots: roots, deniedPaths: denied, deniedCount: deniedCount,
            duration: Date().timeIntervalSince(started), cancelled: isCancelled(), finishedAt: Date())
        lock.unlock()
        return result
    }

    // MARK: - Walking

    /// Fills `node` from the directory open at `fd` (the fd is closed here).
    private func scanDirectory(
        fd: Int32, path: String, node: FileNode, dev: dev_t, depth: Int, collector: UnitCollector?
    ) {
        guard let dir = fdopendir(fd) else {
            close(fd)
            recordDenied(path, errno: errno)
            node.unreadable = true
            node.isFinalized = true
            return
        }
        defer { closedir(dir) }

        var childDirs: [FileNode] = []
        var files: [FileNode] = []
        var residual: Int64 = 0
        var smallFiles = 0
        var entries = 0
        var bytes: Int64 = 0

        while let entry = readdir(dir) {
            if isCancelled() { break }
            withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { name in
                    if name[0] == 46 && (name[1] == 0 || (name[1] == 46 && name[2] == 0)) { return }
                    entries += 1
                    let kind = entry.pointee.d_type
                    if kind == UInt8(DT_LNK) { return }
                    var st = stat()
                    guard fstatat(dirfd(dir), name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                    let type = st.st_mode & S_IFMT

                    if type == S_IFDIR {
                        guard st.st_dev == dev else { return }
                        let childName = String(cString: name)
                        let childPath = path == "/" ? "/" + childName : path + "/" + childName
                        if isExcluded(childPath) { return }
                        let child = FileNode(
                            name: childName, path: childPath, isDirectory: true,
                            modified: Self.date(st.st_mtimespec), changed: Self.date(st.st_ctimespec))
                        childDirs.append(child)
                        if let collector {
                            if depth + 1 >= collector.splitDepth {
                                collector.units.append(.init(node: child, dev: dev))
                                return
                            }
                        }
                        let childFd = openat(dirfd(dir), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if childFd < 0 {
                            child.unreadable = true
                            child.isFinalized = true
                            recordDenied(childPath, errno: errno)
                            return
                        }
                        scanDirectory(
                            fd: childFd, path: childPath, node: child, dev: dev, depth: depth + 1, collector: collector)
                    } else if type == S_IFREG {
                        if st.st_nlink > 1 && !firstSight(st) { return }
                        let size = Int64(st.st_blocks) * 512
                        bytes += size
                        if size >= options.minFileSize {
                            let fileName = String(cString: name)
                            files.append(
                                FileNode(
                                    name: fileName, path: path == "/" ? "/" + fileName : path + "/" + fileName,
                                    isDirectory: false, size: size, fileCount: 1,
                                    modified: Self.date(st.st_mtimespec), changed: Self.date(st.st_ctimespec)))
                        } else {
                            residual += size
                            smallFiles += 1
                        }
                    }
                }
            }
        }

        node.children = childDirs + files
        node.residual = residual
        node.fileCount = smallFiles

        lock.lock()
        itemCount += entries
        byteCount += bytes
        currentPath = path
        lock.unlock()

        if collector == nil { finalize(node) }
    }

    /// Children are already final when this runs (post-order). Folds small directories into the residual.
    private func finalize(_ node: FileNode) {
        guard !node.isFinalized else { return }
        var kept: [FileNode] = []
        var residual = node.residual
        var count = node.fileCount
        for child in node.children {
            count += child.fileCount
            if child.isDirectory && child.size < options.minNodeSize {
                residual += child.size
            } else {
                child.parent = node
                kept.append(child)
            }
        }
        kept.sort { $0.size > $1.size }
        node.children = kept
        node.residual = residual
        node.fileCount = count
        node.recomputeSize()
        node.isFinalized = true
    }

    private func finalizeTree(_ node: FileNode) {
        if node.isFinalized { return }
        for child in node.children where child.isDirectory { finalizeTree(child) }
        finalize(node)
    }

    // MARK: - Helpers

    private func isExcluded(_ path: String) -> Bool {
        for prefix in options.excludedPrefixes where path == prefix || path.hasPrefix(prefix + "/") { return true }
        return false
    }

    private func firstSight(_ st: stat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted
    }

    private func recordDenied(_ path: String, errno code: Int32) {
        guard code == EACCES || code == EPERM else { return }
        lock.lock()
        deniedCount += 1
        if denied.count < Self.deniedCap { denied.append(path) }
        lock.unlock()
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func date(_ ts: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(ts.tv_sec)) }
}
