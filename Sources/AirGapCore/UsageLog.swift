import Foundation

/// The key one app or site is logged under everywhere: `web:<host>` or `app:<bundle id>`.
public enum ActivityKey {
    public static func web(_ host: String) -> String { "web:" + host }
    public static func app(_ bundleID: String) -> String { "app:" + bundleID }
    public static func isWeb(_ key: String) -> Bool { key.hasPrefix("web:") }
    public static func isApp(_ key: String) -> Bool { key.hasPrefix("app:") }
    /// Host for websites, bundle id for apps.
    public static func identifier(_ key: String) -> String { String(key.dropFirst(4)) }
}

/// Seconds spent per activity per day, keyed by `ActivityKey`.
public struct UsageLog: Codable, Equatable, Sendable {
    public var days: [String: [String: TimeInterval]] = [:]
    /// Seconds per rule id per day, used to enforce daily limits. Only today is kept once `prune` runs.
    public var ruleDays: [String: [String: TimeInterval]] = [:]
    /// Bundle id -> display name, so app rows keep a readable name after the app quits.
    public var appNames: [String: String] = [:]
    /// Times each activity was opened (brought to the front) per day, same keys as `days`.
    public var visitDays: [String: [String: Int]] = [:]
    /// Seconds per activity per local hour (24 entries, index = hour) per day, same keys as `days`. Kept for `hourDetailDays`.
    public var hours: [String: [[String: TimeInterval]]] = [:]
    public static let hourDetailDays = 60

    public init() {}

    // Hand-written so missing fields decode as empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .days) ?? [:]
        ruleDays = try c.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .ruleDays) ?? [:]
        appNames = try c.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
        visitDays = try c.decodeIfPresent([String: [String: Int]].self, forKey: .visitDays) ?? [:]
        hours = (try c.decodeIfPresent([String: [[String: TimeInterval]]].self, forKey: .hours) ?? [:]).filter { $0.value.count == 24 }
    }

    public mutating func recordVisit(context: ActivityContext, on date: Date) {
        visitDays[Self.dayKey(date), default: [:]][Self.key(for: context), default: 0] += 1
        appNames[context.bundleID] = context.appName
    }

    public static func key(for context: ActivityContext) -> String {
        context.webHost.map(ActivityKey.web) ?? ActivityKey.app(context.bundleID)
    }

    /// With `logActivity` false only the rule time is counted, so daily limits keep working for items the user chose not to log.
    public mutating func record(_ seconds: TimeInterval, context: ActivityContext, matchedRules: [BlockRule], on date: Date, logActivity: Bool = true,
                                calendar: Calendar = .current) {
        let day = Self.dayKey(date, calendar: calendar)
        for rule in matchedRules {
            ruleDays[day, default: [:]][rule.id.uuidString, default: 0] += seconds
        }
        guard logActivity else { return }
        let key = Self.key(for: context)
        days[day, default: [:]][key, default: 0] += seconds
        hours[day, default: Array(repeating: [:], count: 24)][calendar.component(.hour, from: date)][key, default: 0] += seconds
        appNames[context.bundleID] = context.appName
    }

    /// Seconds per activity for each hour of `date`'s day: always 24 entries, empty when nothing was logged.
    public func hourly(on date: Date, calendar: Calendar = .current) -> [[String: TimeInterval]] {
        hours[Self.dayKey(date, calendar: calendar)] ?? Array(repeating: [:], count: 24)
    }

    /// Drops hourly detail older than `keepingDays` days (today included), and rule time from before today,
    /// which only daily limits read. Daily totals are kept.
    public mutating func prune(keepingDays: Int = hourDetailDays, now: Date, calendar: Calendar = .current) {
        let today = Self.dayKey(now, calendar: calendar)
        ruleDays = ruleDays.filter { $0.key == today }
        guard let oldest = calendar.date(byAdding: .day, value: -(keepingDays - 1), to: now) else { return }
        let cutoff = Self.dayKey(oldest, calendar: calendar)
        hours = hours.filter { $0.key >= cutoff }
    }

    /// Removes every day's time and opens for one activity (`web:<host>` or `app:<bundle id>`).
    public mutating func remove(key: String) {
        for day in days.keys {
            days[day]?[key] = nil
            if days[day]?.isEmpty == true { days[day] = nil }
        }
        for day in hours.keys {
            for hour in 0..<24 { hours[day]?[hour][key] = nil }
            if hours[day]?.allSatisfy(\.isEmpty) == true { hours[day] = nil }
        }
        for day in visitDays.keys {
            visitDays[day]?[key] = nil
            if visitDays[day]?.isEmpty == true { visitDays[day] = nil }
        }
        if ActivityKey.isApp(key) { appNames[ActivityKey.identifier(key)] = nil }
    }

    public func secondsByRule(on date: Date) -> [UUID: TimeInterval] {
        var result: [UUID: TimeInterval] = [:]
        for (id, seconds) in ruleDays[Self.dayKey(date)] ?? [:] {
            if let uuid = UUID(uuidString: id) { result[uuid] = seconds }
        }
        return result
    }

    /// Totals for the given number of days ending on `date`, largest first by `order`.
    public func totals(lastDays count: Int, endingOn date: Date, sortedBy order: UsageSort = .time, calendar: Calendar = .current) -> [UsageEntry] {
        var sums: [String: TimeInterval] = [:]
        var opens: [String: Int] = [:]
        for offset in 0..<max(count, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            for (key, seconds) in days[Self.dayKey(day, calendar: calendar)] ?? [:] {
                sums[key, default: 0] += seconds
            }
            for (key, count) in visitDays[Self.dayKey(day, calendar: calendar)] ?? [:] {
                opens[key, default: 0] += count
                sums[key, default: 0] += 0
            }
        }
        return sums
            .map { UsageEntry(key: $0.key, seconds: $0.value, visits: opens[$0.key, default: 0], appName: appNames[ActivityKey.identifier($0.key)]) }
            .sorted(by: order.areInIncreasingOrder)
    }

    /// Total seconds per day for the given number of days ending on `date`, oldest first.
    public func dailyTotals(lastDays count: Int, endingOn date: Date, calendar: Calendar = .current) -> [(day: Date, seconds: TimeInterval)] {
        (0..<max(count, 1)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let total = (days[Self.dayKey(day, calendar: calendar)] ?? [:]).values.reduce(0, +)
            return (calendar.startOfDay(for: day), total)
        }
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public enum UsageSort: String, CaseIterable, Sendable {
    case time, opens

    /// Largest first by this order's measure, the other one breaking ties.
    public func areInIncreasingOrder(_ a: UsageEntry, _ b: UsageEntry) -> Bool {
        switch self {
        case .time: (a.seconds, a.visits) > (b.seconds, b.visits)
        case .opens: (a.visits, a.seconds) > (b.visits, b.seconds)
        }
    }
}

public struct UsageEntry: Identifiable, Equatable, Sendable {
    public var key: String
    public var seconds: TimeInterval
    public var visits: Int
    public var appName: String?
    /// For a grouped row, every app and site counted in it. Empty for a plain row.
    public var members: [UsageEntry] = []

    public var id: String { key }
    public var isGroup: Bool { !members.isEmpty }
    /// The logged apps and sites behind this row.
    public var parts: [UsageEntry] { isGroup ? members : [self] }
    public var isWeb: Bool { ActivityKey.isWeb(key) }
    /// Host for websites, bundle id for apps.
    public var identifier: String { ActivityKey.identifier(key) }
    public var title: String { isWeb ? identifier : (appName ?? identifier) }
}
