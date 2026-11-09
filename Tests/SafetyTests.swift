import Foundation
import Testing

@Suite struct SafetyGuardTests {
    private func make() -> (Sandbox, SafetyGuard, String) {
        let box = Sandbox()
        let home = box.dir("Users/me")
        return (box, SafetyGuard(home: home), home)
    }

    @Test func allowsCatalogDeletionsInsideHome() {
        let (_, g, home) = make()
        #expect(g.check(home + "/Library/Caches/com.foo", mode: .delete, origin: .catalog) == .allowed)
        #expect(g.check(home + "/Projects/app/node_modules", mode: .delete, origin: .catalog) == .allowed)
        #expect(g.check(home + "/Downloads/x.dmg", mode: .trash, origin: .catalog) == .allowed)
    }

    @Test func refusesProtectedFoldersThemselvesButNotTheirContents() {
        let (_, g, home) = make()
        for name in ["", "/Library", "/Library/Caches", "/Documents", "/Desktop", "/Downloads", "/.Trash", "/Pictures"]
        {
            #expect(!g.check(home + name, mode: .trash, origin: .catalog).isAllowed, "\(name) must be protected")
        }
        #expect(g.check(home + "/Documents/old-project", mode: .trash, origin: .manual) == .allowed)
    }

    @Test func refusesSystemAndRootPaths() {
        let (_, g, _) = make()
        for path in [
            "/", "/System", "/System/Library/Foo", "/usr/bin/ls", "/bin/sh", "/etc/hosts", "/private/etc/hosts",
            "/private/var/db/x", "/Applications", "/Users", "/Library", "/Volumes", "/Library/Caches",
        ] {
            #expect(!g.check(path, mode: .delete, origin: .catalog).isAllowed, "\(path) must be refused")
        }
        #expect(!g.check("relative/path", mode: .delete, origin: .catalog).isAllowed)
        #expect(!g.check("", mode: .delete, origin: .catalog).isAllowed)
    }

    @Test func refusesPrivateAndSyncedData() {
        let (_, g, home) = make()
        for rel in [
            "/.ssh/id_ed25519", "/.gnupg/key", "/Library/Keychains/login.keychain-db",
            "/Library/Mobile Documents/com~apple~CloudDocs/x", "/Library/CloudStorage/OneDrive/x",
            "/Library/Mail/V10/x",
            "/Pictures/Photos Library.photoslibrary", "/Pictures/Photos Library.photoslibrary/originals/a.heic",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ] {
            #expect(!g.check(home + rel, mode: .trash, origin: .catalog).isAllowed, "\(rel) must be refused")
        }
    }

    @Test func dotDotCannotEscapeToTheSystem() {
        let (_, g, home) = make()
        #expect(
            !g.check(home + "/Library/Caches/../../../../../../etc/hosts", mode: .delete, origin: .catalog).isAllowed)
        #expect(!g.check(home + "/Library/Caches/../../..", mode: .delete, origin: .catalog).isAllowed)
        #expect(!g.check(home + "/../../../System/Library", mode: .delete, origin: .catalog).isAllowed)
        #expect(g.check(home + "/Library/Caches/a/../b", mode: .delete, origin: .catalog) == .allowed)
    }

    @Test func symlinkedParentCannotSmuggleASystemPath() throws {
        let (box, g, home) = make()
        try FileManager.default.createSymbolicLink(atPath: home + "/innocent", withDestinationPath: "/System")
        #expect(!g.check(home + "/innocent/Library", mode: .delete, origin: .catalog).isAllowed)
        try FileManager.default.createSymbolicLink(atPath: home + "/tohome", withDestinationPath: "/etc")
        #expect(!g.check(home + "/tohome/hosts", mode: .delete, origin: .catalog).isAllowed)
        // The link itself may go: removing it never touches the target.
        #expect(g.check(home + "/innocent", mode: .delete, origin: .catalog) == .allowed)
        _ = box
    }

    @Test func thingsYouPickYourselfOnlyGoToTheTrash() {
        let (_, g, home) = make()
        #expect(g.check(home + "/Movies/a.mov", mode: .trash, origin: .manual) == .allowed)
        #expect(!g.check(home + "/Movies/a.mov", mode: .delete, origin: .manual).isAllowed)
    }

    @Test func appsMayBeTrashedButNeverDeletedOrNested() {
        let (_, g, _) = make()
        #expect(g.check("/Applications/Foo.app", mode: .trash, origin: .manual) == .allowed)
        #expect(!g.check("/Applications/Foo.app", mode: .delete, origin: .catalog).isAllowed)
        #expect(!g.check("/Applications/Foo.app/Contents/MacOS/foo", mode: .trash, origin: .manual).isAllowed)
        #expect(!g.check("/Applications/Folder", mode: .trash, origin: .manual).isAllowed)
    }

    @Test func onlyAllowlistedSystemFoldersMayBeDeletedAndEscalated() {
        let (_, g, home) = make()
        #expect(g.check("/Library/Caches/com.vendor.thing", mode: .delete, origin: .catalog) == .allowed)
        #expect(g.mayEscalate("/Library/Caches/com.vendor.thing"))
        #expect(g.mayEscalate("/Library/Logs/DiagnosticReports/x.ips"))
        #expect(g.mayEscalate("/private/var/log/system.log.0.gz"))
        #expect(!g.mayEscalate("/Library/Preferences/x.plist"))
        #expect(!g.mayEscalate("/Library/Caches"))
        #expect(!g.mayEscalate("/System/Library/Caches/x"))
        #expect(!g.mayEscalate("/usr/local/bin/tool"))
        #expect(!g.mayEscalate(home + "/Library/Caches/x"), "inside home there is nothing to escalate")
        #expect(!g.check("/Library/Caches/x", mode: .trash, origin: .catalog).isAllowed)
        #expect(!g.check("/Library/Caches/x", mode: .delete, origin: .manual).isAllowed)
    }

    @Test func canonicalHandlesEdgeCases() {
        #expect(SafetyGuard.canonical("/") == "/")
        #expect(SafetyGuard.canonical("/a//b/./c/") == "/a/b/c")
        #expect(SafetyGuard.canonical("/a/b/../../..") == "/")
        #expect(SafetyGuard.canonical("nope") == nil)
        #expect(SafetyGuard.canonical("/tmp/zzz-does-not-exist") != nil)
    }
}

@Suite struct QuotingTests {
    private let nasty = [
        "plain", "with space", "it's", "'", "''", "a'b'c", "$HOME", "`id`", "$(id)", "a;b", "a && b", "tab\there",
        "new\nline", "back\\slash", "dq\"uote", "ünïcödé 日本語 🙂", "*?[]{}", "-rf", "--", "~", "",
    ]

    @Test func shellQuoteRoundTripsThroughARealShell() throws {
        for value in nasty {
            let out = try run("/bin/sh", ["-c", "printf %s " + ShellQuote.quote(value)])
            #expect(out == value, "round trip of \(value.debugDescription)")
        }
    }

    @Test func shellCommandKeepsEveryArgumentSeparate() throws {
        let argv = ["printf", "%s|", "a b", "c'd", "$HOME"]
        let out = try run("/bin/sh", ["-c", ShellQuote.command(argv)])
        #expect(out == "a b|c'd|$HOME|")
    }

    @Test func appleScriptLiteralRoundTripsThroughOsascript() throws {
        for value in nasty {
            // osascript prints the result followed by one newline.
            let out = try run("/usr/bin/osascript", ["-e", "return " + AppleScriptQuote.literal(value)])
            #expect(out == value + "\n", "AppleScript round trip of \(value.debugDescription)")
        }
    }

    @Test func adminScriptCompilesEvenWithHostilePaths() {
        let hostile = [
            "/Library/Caches/it's \"quoted\" $(rm -rf ~)", "/Library/Caches/new\nline", "/Library/Caches/日本語",
        ]
        let source = AdminPromptRunner.script(
            commands: [["/bin/rm", "-rf", "--"] + hostile], prompt: "Apagar \"3\" itens\nde sistema")
        #expect(source.contains("with administrator privileges"))
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        #expect(script?.compileAndReturnError(&error) == true, "\(String(describing: error))")
    }

    @Test func adminScriptNeverLeaksARawPathOutsideQuotes() {
        let path = "/Library/Caches/evil'; touch /tmp/pwned; echo '"
        let script = AdminPromptRunner.script(commands: [["/bin/rm", "-rf", "--", path]], prompt: "x")
        #expect(
            script.contains("'\\\\''"), "single quote is closed, escaped and reopened inside the AppleScript literal")
        #expect(!script.contains("evil'; touch"))
    }

    private func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
