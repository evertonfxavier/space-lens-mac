import Darwin
import Foundation

/// The last line of defence before anything is deleted. It looks only at the path (canonicalised, symlinks in
/// the parents resolved, `..` removed), so no caller, catalog bug or UI mistake can reach the system.
public struct SafetyGuard: Sendable {
    public enum Origin: Sendable {
        /// Came from a recognised recommendation.
        case catalog
        /// You picked it yourself in the explorer.
        case manual
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    public let home: String
    private let protectedExact: Set<String>
    private let protectedInside: [String]
    private let adminInside: [String]

    public init(home: String) {
        let h = Self.canonical(home) ?? home
        self.home = h
        var exact: Set<String> = [
            "/", "/System", "/Library", "/Users", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
            "/opt", "/Volumes", "/cores", "/dev", "/tmp", "/private/var", "/private/etc", "/Users/Shared", h,
        ]
        for rel in [
            "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
            ".Trash", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
            "Library/Containers", "Library/Group Containers", "Library/Messages", "Library/Mail",
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains",
        ] {
            exact.insert(h + "/" + rel)
        }
        self.protectedExact = exact
        self.protectedInside = [
            "/System", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/private/var/vm", "/dev", "/cores",
            "/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share",
            h + "/Library/Keychains", h + "/.ssh", h + "/.gnupg", h + "/Library/Mobile Documents",
            h + "/Library/CloudStorage", h + "/Library/Mail", h + "/Library/Application Support/com.apple.TCC",
            h + "/Library/Application Support/AddressBook", h + "/Library/Messages/chat.db",
        ]
        self.adminInside = ["/Library/Caches", "/Library/Logs", "/Library/Updates", "/private/var/log"]
    }

    /// Whether `path` may be removed with `mode`.
    public func check(_ path: String, mode: RemovalMode, origin: Origin) -> Verdict {
        guard path.hasPrefix("/") else { return .denied("Caminho inválido.") }
        guard let canonical = Self.canonical(path) else { return .denied("Caminho inválido.") }
        if protectedExact.contains(canonical) {
            return .denied(
                "Pasta protegida: apagar “\((canonical as NSString).lastPathComponent)” inteira não é seguro.")
        }
        for prefix in protectedInside where canonical == prefix || canonical.hasPrefix(prefix + "/") {
            return .denied("Área protegida do sistema ou dos seus dados pessoais.")
        }
        if canonical.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return .denied("Biblioteca do Fotos: use o app Fotos para liberar espaço.")
        }
        if origin == .manual && mode != .trash {
            return .denied("Itens escolhidos por você só podem ir para a Lixeira.")
        }
        if canonical.hasPrefix(home + "/") { return .allowed }
        if isInsideAdminArea(canonical) {
            return mode == .delete ? .allowed : .denied("Itens do sistema não vão para a Lixeira.")
        }
        let parts = canonical.split(separator: "/")
        if parts.count == 2, parts[0] == "Applications", parts[1].hasSuffix(".app"), mode == .trash {
            return .allowed
        }
        return .denied("Fora da sua pasta pessoal.")
    }

    /// Only the system caches and logs on the allowlist may ever be removed with an administrator password.
    public func mayEscalate(_ path: String) -> Bool {
        guard let canonical = Self.canonical(path), check(path, mode: .delete, origin: .catalog).isAllowed else {
            return false
        }
        return isInsideAdminArea(canonical)
    }

    private func isInsideAdminArea(_ canonical: String) -> Bool {
        adminInside.contains { canonical.hasPrefix($0 + "/") }
    }

    /// Absolute, `.`/`..` removed, symlinks in the parent directory resolved. A symlink at the last position is
    /// kept as is, because removing it removes the link and not its target.
    public static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var stack: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(part)
        }
        guard let last = stack.last else { return "/" }
        let parent = "/" + stack.dropLast().joined(separator: "/")
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedParent: String
        if realpath(parent, &resolved) != nil {
            resolvedParent = String(cString: resolved)
        } else {
            resolvedParent = parent
        }
        return (resolvedParent == "/" ? "" : resolvedParent) + "/" + last
    }
}
