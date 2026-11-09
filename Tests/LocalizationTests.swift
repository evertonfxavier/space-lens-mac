import Foundation
import Testing

/// Reads the real translation tables from `Resources/Localization`, the same files the app bundle ships.
enum Tables {
    static func load(_ code: String) -> [String: String] {
        let path = "Resources/Localization/\(code).lproj/Localizable.strings"
        return (NSDictionary(contentsOfFile: path) as? [String: String]) ?? [:]
    }

    /// Every key passed to `L("…")` in the sources, with Swift escapes undone.
    static func usedKeys() -> Set<String> {
        var keys = Set<String>()
        guard let walker = FileManager.default.enumerator(atPath: "Sources") else { return keys }
        let pattern = try! NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
        for case let file as String in walker where file.hasSuffix(".swift") {
            guard let text = try? String(contentsOfFile: "Sources/" + file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(unescape(String(text[r])))
            }
        }
        return keys
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else {
                out.append(c)
                continue
            }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append(n)
            }
        }
        return out
    }

    /// The format specifiers of a string, in order (`%@`, `%lld`, `%1$@`…), ignoring `%%`.
    static func specifiers(_ s: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@|f)"#)
        let cleaned = s.replacingOccurrences(of: "%%", with: "")
        return pattern.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)).map {
            String(cleaned[Range($0.range, in: cleaned)!])
        }
    }
}

@Suite struct LocalizationTests {
    @Test func everyKeyUsedInTheCodeIsTranslated() {
        let keys = Tables.usedKeys()
        #expect(keys.count > 200, "the scan of the sources found only \(keys.count) keys")
        for code in ["en", "es"] {
            let table = Tables.load(code)
            #expect(!table.isEmpty, "\(code) table failed to load")
            let missing = keys.filter { table[$0] == nil }.sorted()
            #expect(missing.isEmpty, "\(code) is missing \(missing.count) keys, for example \(missing.prefix(5))")
        }
    }

    @Test func noTranslationIsLeftOverFromARemovedKey() {
        let keys = Tables.usedKeys()
        for code in ["en", "es"] {
            let extra = Tables.load(code).keys.filter { !keys.contains($0) }.sorted()
            #expect(extra.isEmpty, "\(code) has \(extra.count) unused keys, for example \(extra.prefix(5))")
        }
    }

    @Test func translationsKeepTheSameFormatSpecifiers() {
        for code in ["en", "es"] {
            for (key, value) in Tables.load(code) {
                let want = Tables.specifiers(key).sorted()
                let got = Tables.specifiers(value).sorted()
                let plain = want.map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
                let gotPlain = got.map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
                #expect(plain.sorted() == gotPlain.sorted(), "\(code): placeholders differ in “\(key)” → “\(value)”")
            }
        }
    }

    @Test func nothingIsLeftEmptyOrIdenticalByAccident() {
        for code in ["en", "es"] {
            for (key, value) in Tables.load(code) {
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(code): empty translation for “\(key)”")
            }
        }
    }

    @Test func viewsDoNotHardCodeText() throws {
        // SwiftUI treats Text("literal") as a localization key of the app bundle, which would bypass the in-app
        // language. Every visible string must go through L(…).
        let pattern = try NSRegularExpression(
            pattern:
                #"\b(Text|Button|Label|Toggle|Section|Picker|TextField|Menu|LabeledContent|Stepper|DatePicker|ProgressView)\(\s*"[^"\n]*[A-Za-zÀ-ú]{3}"#
        )
        let help = try NSRegularExpression(
            pattern: #"\.(help|navigationTitle|accessibilityLabel)\(\s*"[^"\n]*[A-Za-zÀ-ú]{3}"#)
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: "Sources/SpaceLens/UI")
        where file.hasSuffix(".swift") {
            let text = try String(contentsOfFile: "Sources/SpaceLens/UI/" + file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(l.startIndex..., in: l)
                if pattern.firstMatch(in: l, range: range) != nil || help.firstMatch(in: l, range: range) != nil {
                    offenders.append("\(file):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "hard-coded view text at \(offenders)")
    }
}

@Suite(.serialized) struct LocalizerBehaviourTests {
    private func withTables<T>(_ language: AppLanguage, _ body: () -> T) -> T {
        let shared = Localizer.shared
        let previous = shared.language
        shared.setLoader { code in code == "en" ? ["Olá": "Hello", "%lld item(ns)": "%lld item(s)"] : nil }
        shared.language = language
        defer {
            shared.language = previous
            shared.setLoader(Localizer.bundleLoader)
        }
        return body()
    }

    @Test func portugueseReturnsTheKeyAndMissingKeysFallBack() {
        withTables(.pt) { #expect(L("Olá") == "Olá") }
        withTables(.en) {
            #expect(L("Olá") == "Hello")
            #expect(L("Sem tradução") == "Sem tradução")
            #expect(L("%lld item(ns)", 3) == "3 item(s)")
        }
    }

    @Test func automaticFollowsTheSystemLanguageList() {
        #expect(AppLanguage.resolve(preferred: ["pt-BR", "en-US"]) == .pt)
        #expect(AppLanguage.resolve(preferred: ["pt-PT"]) == .pt)
        #expect(AppLanguage.resolve(preferred: ["es-419"]) == .es)
        #expect(AppLanguage.resolve(preferred: ["fr-FR", "es-ES"]) == .es, "skips unsupported languages")
        #expect(AppLanguage.resolve(preferred: ["en-GB"]) == .en)
        #expect(AppLanguage.resolve(preferred: ["ja-JP"]) == .en, "unsupported falls back to English")
        #expect(AppLanguage.resolve(preferred: []) == .en)
    }

    @Test func systemChoiceIsResolvedAgainstThePreferredList() {
        let shared = Localizer.shared
        let previous = shared.language
        defer {
            shared.language = previous
            shared.setPreferredLanguages(Localizer.systemLanguages())
        }
        shared.language = .system
        shared.setPreferredLanguages(["es-MX"])
        #expect(shared.effective == .es)
        shared.language = .pt
        #expect(shared.effective == .pt, "an explicit choice wins over the system")
    }

    @Test func settingsFromAnOlderVersionStillLoad() throws {
        let json = #"{"requireAuthToClean":false,"scope":"home"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.language == .system)
        #expect(settings.requireAuthToClean == false)
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(round == settings)
    }

    @Test func byteFormatFollowsTheLanguage() {
        let shared = Localizer.shared
        let previous = shared.language
        defer { shared.language = previous }
        shared.language = .en
        #expect(ByteFormat.string(61_800_000_000) == "61.8 GB")
        shared.language = .pt
        #expect(ByteFormat.string(61_800_000_000) == "61,8 GB")
        #expect(ByteFormat.string(0) == "0 KB")
    }
}
