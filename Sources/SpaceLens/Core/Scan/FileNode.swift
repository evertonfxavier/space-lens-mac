import Foundation

/// One directory or one large file in a scan. Small files and small directories are not kept as nodes:
/// their bytes are folded into `residual` of the directory that holds them, which is what keeps a
/// whole-disk scan in memory.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// Allocated bytes on disk (st_blocks * 512), children included.
    public internal(set) var size: Int64
    public internal(set) var fileCount: Int
    public internal(set) var modified: Date?
    public internal(set) var changed: Date?
    /// Directories first or files first does not matter: sorted by size, largest first.
    public internal(set) var children: [FileNode] = []
    /// Bytes inside this directory that no child node represents.
    public internal(set) var residual: Int64 = 0
    public internal(set) weak var parent: FileNode?
    /// The scanner could not open it (permission) or deliberately did not enter it.
    public internal(set) var unreadable = false
    var isFinalized = false

    public var id: String { path }

    public init(
        name: String, path: String, isDirectory: Bool, size: Int64 = 0, fileCount: Int = 0, modified: Date? = nil,
        changed: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.changed = changed
    }

    public var childNodesOrNil: [FileNode]? { children.isEmpty ? nil : children }

    /// Depth-first walk of this node and everything below it.
    public func walk(_ visit: (FileNode) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }

    public func find(path target: String) -> FileNode? {
        if path == target { return self }
        guard target.hasPrefix(path == "/" ? "/" : path + "/") else { return nil }
        for child in children {
            if let hit = child.find(path: target) { return hit }
        }
        return nil
    }

    /// Everything the node represents: a directory's own children and the residual bytes.
    func recomputeSize() {
        size = residual + children.reduce(0) { $0 + $1.size }
    }
}
