import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview, recommendations, categories, explorer, duplicates, routines, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("Visão geral")
        case .recommendations: return L("Recomendações")
        case .categories: return L("Categorias")
        case .explorer: return L("Explorar")
        case .duplicates: return L("Duplicados")
        case .routines: return L("Rotinas")
        case .history: return L("Histórico")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .recommendations: return "sparkles"
        case .categories: return "chart.pie"
        case .explorer: return "folder.badge.gearshape"
        case .duplicates: return "doc.on.doc"
        case .routines: return "clock.arrow.2.circlepath"
        case .history: return "list.bullet.rectangle"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning(items: Int, bytes: Int64, path: String)
    case analyzing
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case failed(String)
}

enum DuplicateState {
    case idle
    case running(done: Int, total: Int)
    case done([DuplicateGroup])
}

struct CleaningReport: Identifiable {
    let id = UUID()
    var title: String
    var result: CleanupResult
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state
    @Published var section: Pane = .overview
    @Published var settings: AppSettings { didSet { if settings != oldValue { settingsChanged(oldValue) } } }
    @Published var routines: [Routine] { didSet { routinesStore.save(routines) } }
    @Published var history: [RunRecord]
    @Published var usage: DiskUsage?
    @Published var phase: ScanPhase = .idle
    @Published var scan: ScanResult?
    @Published var analysis: Analysis?
    @Published var summary: ScanSummary?
    @Published var selection: [String: Set<String>] = [:]
    @Published var duplicates: DuplicateState = .idle
    @Published var duplicateSelection: Set<String> = []
    @Published var busyMessage: String?
    @Published var report: CleaningReport?
    @Published var runningRoutines: Set<UUID> = []
    @Published var fullDiskAccess = FullDiskAccess.isGranted()
    @Published var analysisIsStale = false
    @Published var explorerPath: String?
    @Published var focusedCategory: Category?
    @Published var explorerMap = false
    @Published var expandedRecs: Set<String> = []
    /// Bumps when the interface language changes so every view builds its texts again.
    @Published var languageRevision = 0
    /// The newest GitHub release when it is newer than this build (even if its banner was dismissed).
    @Published var availableUpdate: ReleaseInfo?
    @Published var updateStatus: UpdateStatus = .idle

    // MARK: Services
    let home: String
    private let guardrail: SafetyGuard
    private(set) var cleaner: Cleaner
    private let commands: CommandRunning
    private let auth: AuthGate
    private let notifier = SystemNotifier()
    private let settingsStore: JSONStore<AppSettings>
    private let routinesStore: JSONStore<[Routine]>
    private let historyStore: JSONStore<[RunRecord]>
    private let summaryStore: JSONStore<ScanSummary?>
    var analyzer: Analyzer?
    private let updateChecker: UpdateChecker?

    private var cancelFlag = LockedFlag()
    private var timer: Timer?

    init(
        home: String = NSHomeDirectory(), storeDirectory: URL = JSONStore<Int>.directory(),
        auth: AuthGate = LocalAuthGate(), commands: CommandRunning = ProcessCommandRunner(), startTimers: Bool = true,
        languageOverride: AppLanguage? = nil, updateChecker: UpdateChecker? = AppModel.defaultUpdateChecker()
    ) {
        self.updateChecker = updateChecker
        self.home = home
        self.guardrail = SafetyGuard(home: home)
        self.commands = commands
        self.auth = auth
        self.cleaner = Cleaner(guardrail: SafetyGuard(home: home), commands: commands)
        settingsStore = JSONStore(url: storeDirectory.appendingPathComponent("settings.json"))
        routinesStore = JSONStore(url: storeDirectory.appendingPathComponent("routines.json"))
        historyStore = JSONStore(url: storeDirectory.appendingPathComponent("history.json"))
        summaryStore = JSONStore(url: storeDirectory.appendingPathComponent("summary.json"))
        var loaded = settingsStore.load(default: AppSettings())
        // Only the screenshot harness passes an override; it must not touch the real preferences.
        if let languageOverride { loaded.language = languageOverride }
        settings = loaded
        Localizer.shared.language = loaded.language
        let fresh = !FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("routines.json").path)
        routines = routinesStore.load(default: fresh ? Routine.presets(home: home) : [])
        history = historyStore.load(default: [])
        summary = summaryStore.load(default: nil)
        usage = DiskInfo.current()
        if fresh { routinesStore.save(routines) }
        if startTimers { startTicking() }
    }

    /// Compares against the version in Info.plist. A build without a parseable version (a bare `swiftc` run) never
    /// checks, so it cannot claim to be outdated.
    nonisolated static func defaultUpdateChecker() -> UpdateChecker? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let current = AppVersion(text)
        else { return nil }
        return UpdateChecker(current: current, fetcher: URLSessionFetcher(userAgent: "SpaceLens/\(current)"))
    }

    // MARK: - Derived

    var isBusy: Bool { busyMessage != nil }
    var isScanning: Bool { phase != .idle }

    var recommendations: [Recommendation] { analysis?.recommendations ?? [] }

    func selectedItems(_ rec: Recommendation) -> [CleanupItem] {
        let picked = selection[rec.id] ?? []
        return rec.items.filter { picked.contains($0.path) }
    }

    func selectedSize(_ rec: Recommendation) -> Int64 { selectedItems(rec).reduce(0) { $0 + $1.size } }

    var totalSelectedSize: Int64 {
        recommendations.filter { !$0.sizeIsReference }.reduce(0) { $0 + selectedSize($1) }
    }

    /// What the quick clean (menu bar, overview) does: plain safe items, no password, no external tool.
    var quickCleanRecommendations: [Recommendation] {
        recommendations.filter { $0.safety == .safe && !$0.needsAdmin && !$0.isCommand }
    }

    var quickCleanSize: Int64 {
        quickCleanRecommendations.reduce(0) { total, rec in total + selectedSize(rec) }
    }

    var freeSpaceText: String { usage.map { ByteFormat.string($0.availableImportant) } ?? "—" }

    var isLowOnSpace: Bool {
        guard let usage else { return false }
        return usage.availableImportant < Int64(settings.lowSpaceThresholdGB) << 30
    }

    func nodeClass(_ node: FileNode) -> NodeClass { analyzer?.classify(node) ?? .unknown }

    func trashVerdict(_ node: FileNode) -> SafetyGuard.Verdict {
        guardrail.check(node.path, mode: .trash, origin: .manual)
    }

    // MARK: - Scanning

    func scanRoots() -> [String] {
        switch settings.scope {
        case .home: return [home]
        case .wholeDisk:
            return [home, "/Applications", "/Library", "/private", "/opt", "/usr/local", "/Users/Shared"]
        }
    }

    func startScan() {
        guard !isScanning else { return }
        phase = .scanning(items: 0, bytes: 0, path: "")
        cancelFlag = LockedFlag()
        let flag = cancelFlag
        let roots = scanRoots()
        let excluded = [home + "/Library/CloudStorage"]
        let home = self.home
        let tools = commands
        Task.detached(priority: .utility) { [self] in
            let scanner = DiskScanner(
                options: ScanOptions(roots: roots, excludedPrefixes: excluded), isCancelled: { flag.isSet })
            let result = scanner.scan { progress in
                Task { @MainActor in
                    guard case .scanning = self.phase else { return }
                    self.phase = .scanning(items: progress.items, bytes: progress.bytes, path: progress.currentPath)
                }
            }
            if result.cancelled {
                await MainActor.run { self.phase = .idle }
                return
            }
            await MainActor.run { self.phase = .analyzing }
            let analyzer = Analyzer(home: home, toolExists: { tools.resolve($0) != nil })
            var analysis = analyzer.analyze(result.roots)
            if let dates = await Self.localSnapshots(tools), let rec = TimeMachineSnapshots.recommendation(dates: dates)
            {
                analysis.recommendations.append(rec)
                analysis.recommendations.sort {
                    $0.safety != $1.safety ? $0.safety < $1.safety : $0.totalSize > $1.totalSize
                }
            }
            let finalAnalysis = analysis
            await MainActor.run { self.finishScan(result, analyzer, finalAnalysis) }
        }
    }

    func cancelScan() { cancelFlag.set() }

    private func finishScan(_ result: ScanResult, _ analyzer: Analyzer, _ analysis: Analysis) {
        self.scan = result
        self.analyzer = analyzer
        self.analysis = analysis
        self.analysisIsStale = false
        self.selection = Dictionary(
            uniqueKeysWithValues: analysis.recommendations.map { rec in
                (rec.id, Set(rec.items.filter(\.preselected).map(\.path)))
            })
        self.duplicates = .idle
        self.duplicateSelection = []
        self.explorerPath = nil
        let summary = ScanSummary(result: result, analysis: analysis, scope: settings.scope)
        self.summary = summary
        summaryStore.save(summary)
        usage = DiskInfo.current()
        fullDiskAccess = FullDiskAccess.isGranted()
        phase = .idle
    }

    nonisolated private static func localSnapshots(_ tools: CommandRunning) async -> [String]? {
        guard let tmutil = tools.resolve("tmutil") else { return nil }
        let out = await tools.run(executable: tmutil, args: ["listlocalsnapshotdates", "/"])
        return out.status == 0 ? TimeMachineSnapshots.parse(out.output) : nil
    }

    // MARK: - Selection

    func toggle(_ rec: Recommendation, _ item: CleanupItem) {
        var set = selection[rec.id] ?? []
        if set.contains(item.path) { set.remove(item.path) } else { set.insert(item.path) }
        selection[rec.id] = set
    }

    func selectAll(_ rec: Recommendation, _ on: Bool) {
        selection[rec.id] = on ? Set(rec.items.map(\.path)) : []
    }

    // MARK: - Cleaning

    /// One confirmation step, never two: Touch ID / password when the setting asks for it, otherwise an alert that
    /// says what is about to happen (`details`; nil means the caller already asked). System items skip this: macOS
    /// asks for the administrator password (or Touch ID) itself.
    private func confirm(_ reason: String, details: String? = nil, systemItems: Bool = false) async -> Bool {
        guard !systemItems else { return true }
        if settings.requireAuthToClean {
            switch await auth.authenticate(reason: reason) {
            case .approved, .unavailable: return true
            case .cancelled: return false
            case .failed(let message):
                report = CleaningReport(title: L("Não foi possível confirmar"), result: failureResult(message))
                return false
            }
        }
        guard let details else { return true }
        let alert = NSAlert()
        alert.messageText = reason
        alert.informativeText = details
        alert.addButton(withTitle: L("Limpar"))
        alert.addButton(withTitle: L("Cancelar"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func failureResult(_ message: String) -> CleanupResult {
        var r = CleanupResult()
        r.failures = [CleanupFailure(path: "", reason: message)]
        return r
    }

    func clean(_ rec: Recommendation) async {
        let items = selectedItems(rec)
        guard !items.isEmpty, !isBusy else { return }
        let size = items.reduce(0) { $0 + $1.size }
        let what = rec.sizeIsReference ? rec.title : L("%@ de “%@”", ByteFormat.string(size), rec.title)
        let how =
            rec.isCommand
            ? L("Executa: %@", rec.command?.display ?? "")
            : ((rec.mode == .trash || settings.alwaysUseTrash) && !rec.needsAdmin
                ? L("Vai para a Lixeira.") : L("Apaga de vez."))
        guard
            await confirm(
                L("Limpar %@?", what),
                details: [how, rec.consequence].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                systemItems: rec.needsAdmin)
        else { return }
        busyMessage = L("Limpando “%@”…", rec.title)
        let result = await cleaner.perform(rec, selected: items, forceTrash: settings.alwaysUseTrash)
        busyMessage = nil
        applyCleaning(result, to: [rec])
        report = CleaningReport(title: rec.title, result: result)
        record(manual: rec.title, result)
    }

    /// Menu bar / overview shortcut: everything that is safe, ticked and password-free, with one confirmation.
    func quickClean() async {
        let recs = quickCleanRecommendations.filter { selectedSize($0) > 0 }
        guard !recs.isEmpty, !isBusy else { return }
        let size = recs.reduce(0) { $0 + selectedSize($1) }
        let list = recs.map { "• \($0.title) — \(ByteFormat.string(selectedSize($0)))" }.joined(separator: "\n")
        guard
            await confirm(
                L("Liberar %@ com segurança?", ByteFormat.string(size)),
                details:
                    L(
                        "Vai limpar o que está marcado como seguro:\n\n%@\n\nNada seu é perdido: tudo isso é recriado pelo macOS e pelos apps.",
                        list)
            )
        else { return }
        busyMessage = L("Liberando espaço…")
        var total = CleanupResult()
        for rec in recs {
            let r = await cleaner.perform(
                rec, selected: selectedItems(rec), forceTrash: settings.alwaysUseTrash, allowAdmin: false)
            total.freed += r.freed
            total.trashed += r.trashed
            total.removedPaths += r.removedPaths
            total.failures += r.failures
            applyCleaning(r, to: [rec])
        }
        busyMessage = nil
        report = CleaningReport(title: L("Limpeza rápida"), result: total)
        record(manual: L("Limpeza rápida"), total)
    }

    func trashManually(_ nodes: [FileNode]) async {
        guard !nodes.isEmpty, !isBusy else { return }
        let items = nodes.map { CleanupItem(path: $0.path, size: $0.size, modified: $0.modified) }
        let size = items.reduce(0) { $0 + $1.size }
        guard await confirm(L("Confirme para mover %@ para a Lixeira.", ByteFormat.string(size)), details: nil) else {
            return
        }
        busyMessage = L("Movendo para a Lixeira…")
        let result = await cleaner.trashManually(items)
        busyMessage = nil
        usage = DiskInfo.current()
        analysisIsStale = analysisIsStale || result.removedCount > 0
        report = CleaningReport(title: L("Mover para a Lixeira"), result: result)
        record(manual: L("Mover para a Lixeira"), result)
    }

    private func applyCleaning(_ result: CleanupResult, to recs: [Recommendation]) {
        usage = DiskInfo.current()
        guard result.removedCount > 0, var current = analysis else { return }
        let gone = Set(result.removedPaths)
        for index in current.recommendations.indices {
            guard recs.contains(where: { $0.id == current.recommendations[index].id }) else { continue }
            if current.recommendations[index].isCommand
                && current.recommendations[index].items.allSatisfy({ $0.argument == nil })
            {
                continue  // sizes of docker/simulators are references, they are not subtracted
            }
            let removed = current.recommendations[index].items.filter { gone.contains($0.path) }
            current.recommendations[index].items.removeAll { gone.contains($0.path) }
            current.categoryBytes[current.recommendations[index].category, default: 0] -= removed.reduce(0) {
                $0 + $1.size
            }
            selection[current.recommendations[index].id]?.subtract(gone)
        }
        current.recommendations.removeAll { $0.items.isEmpty }
        analysis = current
        analysisIsStale = true
    }

    // MARK: - Duplicates

    func findDuplicates() {
        guard let roots = scan?.roots, case .idle = duplicates else {
            if case .done = duplicates { duplicates = .idle }
            return
        }
        duplicates = .running(done: 0, total: 1)
        Task.detached(priority: .utility) { [self] in
            let files = DuplicateFinder.candidates(in: roots)
            let groups = DuplicateFinder.find(files) { done, total in
                Task { @MainActor in
                    if case .running = self.duplicates { self.duplicates = .running(done: done, total: max(1, total)) }
                }
            }
            await MainActor.run {
                self.duplicates = .done(groups)
                // Keep the oldest copy, tick the rest.
                self.duplicateSelection = Set(groups.flatMap { $0.files.dropFirst().map(\.path) })
            }
        }
    }

    func trashDuplicates() async {
        guard case .done(let groups) = duplicates, !isBusy else { return }
        let nodes: [CleanupItem] = groups.flatMap { group in
            group.removable(selected: duplicateSelection).map {
                CleanupItem(path: $0.path, size: group.size, modified: $0.modified)
            }
        }
        guard !nodes.isEmpty else { return }
        let size = nodes.reduce(0) { $0 + $1.size }
        guard
            await confirm(
                L("Confirme para mover %lld duplicado(s) (%@) para a Lixeira.", nodes.count, ByteFormat.string(size)))
        else { return }
        busyMessage = L("Movendo duplicados para a Lixeira…")
        let result = await cleaner.trashManually(nodes)
        busyMessage = nil
        usage = DiskInfo.current()
        let gone = Set(result.removedPaths)
        duplicates = .done(
            groups.map { group in
                var g = group
                g.files.removeAll { gone.contains($0.path) }
                return g
            }.filter { $0.files.count > 1 })
        duplicateSelection.subtract(gone)
        analysisIsStale = analysisIsStale || result.removedCount > 0
        report = CleaningReport(title: L("Duplicados"), result: result)
        record(manual: L("Duplicados"), result)
    }

    // MARK: - History

    private func record(manual title: String, _ result: CleanupResult) {
        guard result.removedCount > 0 || !result.failures.isEmpty else { return }
        var message =
            result.removedCount > 0 ? L("%lld item(ns).", result.removedCount) : L("Nada removido.")
        if result.freed > 0 { message = L("Liberou %@.", ByteFormat.string(result.freed)) + " " + message }
        if result.trashed > 0 { message += " " + L("%@ na Lixeira.", ByteFormat.string(result.trashed)) }
        if !result.failures.isEmpty { message += " " + L("%lld falha(s).", result.failures.count) }
        addHistory(
            RunRecord(
                routineID: nil, routineName: title, date: Date(), applied: true, freed: result.freed,
                trashed: result.trashed, itemCount: result.removedCount, message: message,
                failed: result.removedCount == 0))
    }

    private func addHistory(_ record: RunRecord) {
        history.insert(record, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        historyStore.save(history)
    }

    func clearHistory() {
        history = []
        historyStore.save(history)
    }

    // MARK: - Routines

    private var routineNotifier: Notifier {
        settings.notifications ? notifier : SilentNotifier()
    }

    func runNow(_ routine: Routine) {
        guard !runningRoutines.contains(routine.id) else { return }
        runningRoutines.insert(routine.id)
        let runner = RoutineRunner(
            home: home, cleaner: cleaner, notifier: routineNotifier,
            toolExists: { [commands] in commands.resolve($0) != nil })
        Task.detached(priority: .utility) { [self] in
            let record = await runner.run(routine)
            await MainActor.run {
                self.runningRoutines.remove(routine.id)
                if let index = self.routines.firstIndex(where: { $0.id == routine.id }) {
                    self.routines[index].lastRun = record.date
                }
                self.addHistory(record)
                self.usage = DiskInfo.current()
                if record.freed > 0 || record.trashed > 0 { self.analysisIsStale = true }
            }
        }
    }

    func deleteRoutine(_ routine: Routine) { routines.removeAll { $0.id == routine.id } }

    func upsert(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
    }

    var nextRoutine: (Routine, Date)? {
        routines.filter(\.enabled).map { ($0, $0.nextRun()) }.min { $0.1 < $1.1 }
    }

    // MARK: - Timers

    private func startTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 10
        Task { @MainActor in
            if settings.notifications { await notifier.requestAuthorization() }
            tick()
        }
    }

    func tick(now: Date = Date()) {
        usage = DiskInfo.current()
        for routine in routines where routine.isDue(at: now) && !runningRoutines.contains(routine.id) {
            runNow(routine)
        }
        if settings.checkForUpdates, updateStatus != .checking,
            now.timeIntervalSince(settings.lastUpdateCheck ?? .distantPast) > 24 * 3600
        {
            Task { await checkForUpdates() }
        }
        let hours = settings.autoScanHours
        if hours > 0, phase == .idle {
            let last = summary?.date ?? .distantPast
            if now.timeIntervalSince(last) > Double(hours) * 3600 { startScan() }
        }
    }

    // MARK: - Updates

    /// The release to announce: newer than this build and not dismissed.
    var visibleUpdate: ReleaseInfo? {
        guard let update = availableUpdate, update.tag != settings.dismissedUpdate else { return nil }
        return update
    }

    func checkForUpdates() async {
        guard let updateChecker, updateStatus != .checking else { return }
        updateStatus = .checking
        let result = await updateChecker.check()
        settings.lastUpdateCheck = Date()
        switch result {
        case .upToDate:
            availableUpdate = nil
            updateStatus = .upToDate
        case .available(let release):
            availableUpdate = release
            updateStatus = .upToDate
        case .failed(let message):
            updateStatus = .failed(message)
        }
    }

    func dismissUpdate() { settings.dismissedUpdate = availableUpdate?.tag }

    func openUpdate(download: Bool) {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(download ? (update.downloadURL ?? update.pageURL) : update.pageURL)
    }

    func refreshAccess() { fullDiskAccess = FullDiskAccess.isGranted() }

    // MARK: - Settings

    private func settingsChanged(_ old: AppSettings) {
        settingsStore.save(settings)
        if old.scope != settings.scope { analysisIsStale = true }
        if old.language != settings.language { applyLanguage() }
        if !old.notifications && settings.notifications {
            Task { await notifier.requestAuthorization() }
        }
    }

    /// Switches every text on screen. The catalog texts inside the current analysis are translated in place, because
    /// a new analysis would bring back items that were already cleaned.
    private func applyLanguage() {
        Localizer.shared.language = settings.language
        // The language list also decides how macOS words its own dialogs, but only at the next launch.
        if settings.language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([settings.language.code], forKey: "AppleLanguages")
        }
        if let current = analysis { analysis = current.relocalized(home: home) }
        if var current = summary {
            let texts = Catalog.texts(home: home)
            for index in current.top.indices {
                if let text = texts[current.top[index].id] { current.top[index].title = text.title }
            }
            summary = current
            summaryStore.save(current)
        }
        languageRevision += 1
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                report = CleaningReport(
                    title: L("Iniciar com o Mac"), result: failureResult(error.localizedDescription))
            }
            objectWillChange.send()
        }
    }
}

struct SilentNotifier: Notifier {
    func notify(title: String, body: String) async {}
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
