import Foundation

public enum ShellQuote {
    /// POSIX single-quote escaping: safe for any string, including quotes, spaces, `$`, backticks and newlines.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }
}

public enum AppleScriptQuote {
    public static func literal(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

public enum PrivilegedError: Error, Equatable, Sendable {
    /// You dismissed the password / Touch ID dialog.
    case cancelled
    case failed(String)
}

public protocol PrivilegedRunner: Sendable {
    /// Runs each argv as root after one macOS authentication prompt (password or Touch ID).
    func run(commands: [[String]], prompt: String) async throws
}

/// Uses the system authorization dialog through `do shell script … with administrator privileges`, run in this
/// process so the dialog carries SpaceLens' name and icon. SpaceLens never sees or stores the password: macOS
/// handles it (password, Touch ID or Apple Watch, whatever the Mac offers).
public struct AdminPromptRunner: PrivilegedRunner {
    public init() {}

    public static func script(commands: [[String]], prompt: String) -> String {
        let shell = commands.map(ShellQuote.command).joined(separator: "; ")
        return "do shell script \(AppleScriptQuote.literal(shell)) with administrator privileges with prompt "
            + AppleScriptQuote.literal(prompt)
    }

    public func run(commands: [[String]], prompt: String) async throws {
        let source = Self.script(commands: commands, prompt: prompt)
        try await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                throw PrivilegedError.failed(L("Script inválido."))
            }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int
                if number == -128 { throw PrivilegedError.cancelled }
                throw PrivilegedError.failed(
                    (error[NSAppleScript.errorMessage] as? String) ?? L("Falha ao executar com privilégios."))
            }
        }
    }
}
