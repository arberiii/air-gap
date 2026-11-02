import Foundation

/// Time in one category during one hour or one day.
public struct CategorySlice: Equatable, Sendable {
    /// Start of the hour for hourly charts, start of the day for daily ones.
    public var bucket: Date
    public var categoryID: String
    public var seconds: TimeInterval

    public init(bucket: Date, categoryID: String, seconds: TimeInterval) {
        self.bucket = bucket
        self.categoryID = categoryID
        self.seconds = seconds
    }
}

/// Screen time totaled by category for the screen time chart. Each app and site counts under its grouped row's category.
public enum UsageChart {
    public static func hourly(_ usage: UsageLog, on date: Date, grouping: UsageGrouping, categories: Categorization,
                              excludedApps: Set<String> = [], calendar: Calendar = .current) -> [CategorySlice] {
        let start = calendar.startOfDay(for: date)
        return usage.hourly(on: date, calendar: calendar).enumerated().flatMap { hour, seconds -> [CategorySlice] in
            guard let bucket = calendar.date(byAdding: .hour, value: hour, to: start) else { return [] }
            return slices(seconds, bucket: bucket, usage: usage, grouping: grouping, categories: categories, excludedApps: excludedApps)
        }
    }

    /// One bucket per day for the `lastDays` ending on `date`, oldest first.
    public static func daily(_ usage: UsageLog, lastDays: Int, endingOn date: Date, grouping: UsageGrouping, categories: Categorization,
                             excludedApps: Set<String> = [], calendar: Calendar = .current) -> [CategorySlice] {
        (0..<max(lastDays, 1)).reversed().flatMap { offset -> [CategorySlice] in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return [] }
            return slices(usage.days[UsageLog.dayKey(day, calendar: calendar)] ?? [:], bucket: calendar.startOfDay(for: day),
                          usage: usage, grouping: grouping, categories: categories, excludedApps: excludedApps)
        }
    }

    /// Each category's share of `rows`, largest first, leaving out empty ones.
    public static func legend(_ rows: [UsageEntry], categories: Categorization) -> [(category: UsageCategory, seconds: TimeInterval)] {
        var sums: [String: TimeInterval] = [:]
        for row in rows { sums[categories.categoryID(of: row.key), default: 0] += row.seconds }
        return categories.categories
            .compactMap { category in sums[category.id].flatMap { $0 > 0 ? (category, $0) : nil } }
            .sorted { $0.seconds > $1.seconds }
    }

    private static func slices(_ seconds: [String: TimeInterval], bucket: Date, usage: UsageLog, grouping: UsageGrouping,
                               categories: Categorization, excludedApps: Set<String>) -> [CategorySlice] {
        var sums: [String: TimeInterval] = [:]
        for (key, value) in seconds {
            let row = grouping.primary(of: key, appNames: usage.appNames, excludedApps: excludedApps)
            sums[categories.categoryID(of: row), default: 0] += value
        }
        return categories.categories.compactMap { category in
            sums[category.id].flatMap { $0 > 0 ? CategorySlice(bucket: bucket, categoryID: category.id, seconds: $0) : nil }
        }
    }
}
