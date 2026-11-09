import Foundation

public enum Schedule: Codable, Equatable, Sendable {
    case everyHours(Int)
    case daily(hour: Int, minute: Int)
    /// `weekday` follows `Calendar`: 1 is Sunday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// `day` is clamped to 1…28 so every month has it.
    case monthly(day: Int, hour: Int, minute: Int)

    public func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .everyHours(let hours):
            return date.addingTimeInterval(Double(max(1, hours)) * 3600)
        case .daily(let hour, let minute):
            return calendar.nextDate(
                after: date, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(86_400)
        case .weekly(let weekday, let hour, let minute):
            return calendar.nextDate(
                after: date, matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 86_400)
        case .monthly(let day, let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(day: min(28, max(1, day)), hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime) ?? date.addingTimeInterval(30 * 86_400)
        }
    }

    public func summary(calendar: Calendar = .current) -> String {
        func time(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        switch self {
        case .everyHours(let n): return n == 1 ? "A cada hora" : "A cada \(n) horas"
        case .daily(let h, let m): return "Todo dia às \(time(h, m))"
        case .weekly(let wd, let h, let m):
            let name = calendar.weekdaySymbols[max(0, min(6, wd - 1))]
            return "Toda \(name) às \(time(h, m))"
        case .monthly(let d, let h, let m): return "Todo dia \(min(28, max(1, d))) às \(time(h, m))"
        }
    }
}

public enum RoutineTask: Codable, Equatable, Sendable {
    /// Caches and logs that are safe to remove and untouched for `minAgeDays`.
    case cleanCaches(minAgeDays: Int)
    case emptyTrash(olderThanDays: Int)
    case cleanDownloads(olderThanDays: Int, installersOnly: Bool)
    /// node_modules, target, .venv… of projects not touched for `inactiveDays`.
    case cleanProjectArtifacts(roots: [String], inactiveDays: Int)
    case lowSpaceAlert(thresholdGB: Int)

    public var title: String {
        switch self {
        case .cleanCaches: return "Limpar caches e logs seguros"
        case .emptyTrash: return "Esvaziar a Lixeira"
        case .cleanDownloads: return "Limpar Downloads antigos"
        case .cleanProjectArtifacts: return "Limpar projetos inativos"
        case .lowSpaceAlert: return "Avisar quando faltar espaço"
        }
    }

    public var detail: String {
        switch self {
        case .cleanCaches(let d): return "Remove caches e logs que o macOS e os apps recriam, parados há \(d)+ dias."
        case .emptyTrash(let d): return "Apaga de vez o que está na Lixeira há mais de \(d) dias."
        case .cleanDownloads(let d, let only):
            return only
                ? "Move para a Lixeira instaladores (.dmg, .pkg, .iso) com mais de \(d) dias."
                : "Move para a Lixeira tudo em Downloads com mais de \(d) dias."
        case .cleanProjectArtifacts(_, let d):
            return "Remove node_modules, target, .venv e similares de projetos sem alteração há \(d)+ dias. Recriáveis."
        case .lowSpaceAlert(let gb): return "Notifica quando o espaço livre cair abaixo de \(gb) GB."
        }
    }
}

public struct Routine: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var schedule: Schedule
    public var task: RoutineTask
    /// false: only look and report what could be freed. true: do it.
    public var apply: Bool
    public var notify: Bool
    public var createdAt: Date
    public var lastRun: Date?

    public init(
        id: UUID = UUID(), name: String, enabled: Bool = true, schedule: Schedule, task: RoutineTask,
        apply: Bool = false, notify: Bool = true, createdAt: Date = Date(), lastRun: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.schedule = schedule
        self.task = task
        self.apply = apply
        self.notify = notify
        self.createdAt = createdAt
        self.lastRun = lastRun
    }

    public func nextRun(calendar: Calendar = .current) -> Date {
        schedule.next(after: lastRun ?? createdAt, calendar: calendar)
    }

    /// A run missed while the app was closed fires once on the next check, never several times.
    public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        enabled && nextRun(calendar: calendar) <= now
    }

    public static func presets(home: String, now: Date = Date()) -> [Routine] {
        [
            Routine(
                name: "Caches e logs toda semana", schedule: .weekly(weekday: 1, hour: 10, minute: 0),
                task: .cleanCaches(minAgeDays: 7), apply: true, createdAt: now),
            Routine(
                name: "Esvaziar Lixeira (30 dias)", schedule: .daily(hour: 12, minute: 0),
                task: .emptyTrash(olderThanDays: 30), apply: false, createdAt: now),
            Routine(
                name: "Instaladores antigos", schedule: .weekly(weekday: 2, hour: 9, minute: 0),
                task: .cleanDownloads(olderThanDays: 30, installersOnly: true), apply: false, createdAt: now),
            Routine(
                name: "Pouco espaço livre", schedule: .everyHours(6), task: .lowSpaceAlert(thresholdGB: 20),
                apply: false, createdAt: now),
        ]
    }
}

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var routineID: UUID?
    public var routineName: String
    public var date: Date
    public var applied: Bool
    public var freed: Int64
    public var trashed: Int64
    /// What could have been freed (reported when the routine only looks).
    public var potential: Int64
    public var itemCount: Int
    public var message: String
    public var failed: Bool

    public init(
        id: UUID = UUID(), routineID: UUID?, routineName: String, date: Date, applied: Bool, freed: Int64 = 0,
        trashed: Int64 = 0, potential: Int64 = 0, itemCount: Int = 0, message: String, failed: Bool = false
    ) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.date = date
        self.applied = applied
        self.freed = freed
        self.trashed = trashed
        self.potential = potential
        self.itemCount = itemCount
        self.message = message
        self.failed = failed
    }
}
