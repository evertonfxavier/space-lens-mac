import Darwin
import Foundation
import Testing

/// A throwaway directory tree. Symlinks in the temp path are resolved so paths match what the scanner reports.
final class Sandbox {
    let root: String

    init() {
        var template = Array((NSTemporaryDirectory() + "spacelens-test-XXXXXX").utf8CString)
        let made = mkdtemp(&template)
        let raw = String(cString: made!)
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        root = realpath(raw, &resolved) != nil ? String(cString: resolved) : raw
    }

    deinit {
        // Directories a test made unreadable must be openable for the removal to work.
        chmodTree(root)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func chmodTree(_ path: String) {
        chmod(path, 0o755)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            let child = path + "/" + name
            var st = stat()
            if lstat(child, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { chmodTree(child) }
        }
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    @discardableResult
    func dir(_ rel: String) -> String {
        try! FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
        return path(rel)
    }

    /// Writes `megabytes` MB of data. `seed` makes contents differ between files.
    @discardableResult
    func file(_ rel: String, megabytes: Double = 0, bytes: Int? = nil, seed: UInt8 = 1) -> String {
        let full = path(rel)
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let count = bytes ?? Int(megabytes * 1_048_576)
        FileManager.default.createFile(atPath: full, contents: Data(repeating: seed, count: count))
        return full
    }

    func age(_ rel: String, days: Double) {
        let date = Date().addingTimeInterval(-days * 86_400)
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(rel))
    }
}

func flatten(_ roots: [FileNode]) -> [String: Int64] {
    var out: [String: Int64] = [:]
    for root in roots { root.walk { out[$0.path] = $0.size } }
    return out
}
