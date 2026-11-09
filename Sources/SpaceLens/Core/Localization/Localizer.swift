import Foundation

/// The languages the interface can be shown in. `system` follows the macOS language list.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case pt
    case en
    case es

    /// The language every user-facing string in the source code is written in. It is also the lookup key.
    public static let source: AppLanguage = .pt

    /// Names are always shown in their own language so you can find yours whatever the current one is.
    public var nativeName: String {
        switch self {
        case .system: return L("Automático (idioma do sistema)")
        case .pt: return "Português"
        case .en: return "English"
        case .es: return "Español"
        }
    }

    /// Folder name of the `.lproj` that holds the translations.
    public var code: String {
        switch self {
        case .system: return "system"
        case .pt: return "pt-BR"
        case .en: return "en"
        case .es: return "es"
        }
    }

    /// Picks the best supported language out of a list of BCP 47 identifiers (`Locale.preferredLanguages`).
    /// Anything unsupported falls back to English.
    public static func resolve(preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "pt": return .pt
            case "es": return .es
            case "en": return .en
            default: continue
            }
        }
        return .en
    }
}

/// Looks strings up by their Brazilian Portuguese text. Missing keys (and Portuguese itself) return the key, so the
/// app never shows an empty label. Thread-safe: the scanner, the cleaner and the UI all call it.
public final class Localizer: @unchecked Sendable {
    public static let shared = Localizer()

    /// Reads `Localizable.strings` for a language code (`en`, `es`). The default looks in the app bundle.
    public typealias Loader = @Sendable (String) -> [String: String]?

    private let lock = NSLock()
    private var chosen: AppLanguage = .system
    private var preferred: [String] = Localizer.systemLanguages()
    private var tables: [AppLanguage: [String: String]] = [:]
    private var loader: Loader = Localizer.bundleLoader

    public init() {}

    /// The macOS language list, read from the global preferences. `Locale.preferredLanguages` would not do: once
    /// you pick a language in SpaceLens it is saved as this app's own `AppleLanguages`, and that override would
    /// then be mistaken for the system language when you go back to "Automatic".
    public static func systemLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        if let list = value as? [String], !list.isEmpty { return list }
        return Locale.preferredLanguages
    }

    public static let bundleLoader: Loader = { code in
        guard
            let path = Bundle.main.path(
                forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code)
        else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// What was picked in settings (may be `.system`).
    public var language: AppLanguage {
        get { locked { chosen } }
        set {
            locked {
                chosen = newValue
                if newValue == .system { preferred = Localizer.systemLanguages() }
            }
        }
    }

    /// The language actually in use: `.system` resolved against the system language list.
    public var effective: AppLanguage {
        locked { chosen == .system ? AppLanguage.resolve(preferred: preferred) : chosen }
    }

    /// For tests: pretend the system language list is something else.
    public func setPreferredLanguages(_ list: [String]) { locked { preferred = list } }

    /// For tests: read the tables from somewhere other than the app bundle.
    public func setLoader(_ newLoader: @escaping Loader) {
        locked {
            loader = newLoader
            tables = [:]
        }
    }

    public func translate(_ key: String) -> String {
        let target = effective
        if target == AppLanguage.source { return key }
        return locked { () -> String in
            if tables[target] == nil { tables[target] = loader(target.code) ?? [:] }
            return tables[target]?[key] ?? key
        }
    }

    /// Locale for dates and numbers shown in the interface.
    public var locale: Locale {
        switch effective {
        case .pt, .system: return Locale(identifier: "pt_BR")
        case .en: return Locale(identifier: "en_US")
        case .es: return Locale(identifier: "es_ES")
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Translates a user-facing string. The Portuguese text is the key.
// swift-format-ignore: AlwaysUseLowerCamelCase
public func L(_ key: String) -> String { Localizer.shared.translate(key) }

/// Translates a format string and fills it in. Use positional specifiers (`%1$@`) when the word order differs.
// swift-format-ignore: AlwaysUseLowerCamelCase
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.translate(key), locale: Localizer.shared.locale, arguments: args)
}
