import Foundation

/// Screen time as CSV, one row per day per app or site, oldest day first, so it opens in any spreadsheet.
public enum UsageExport {
    public static let header = "date,type,name,identifier,category,minutes,opens"

    public static func csv(_ usage: UsageLog, categorization: Categorization) -> String {
        let dayKeys = Set(usage.days.keys).union(usage.visitDays.keys).sorted()
        var lines = [header]
        for day in dayKeys {
            let seconds = usage.days[day] ?? [:]
            let opens = usage.visitDays[day] ?? [:]
            let rows = Set(seconds.keys).union(opens.keys).map {
                UsageEntry(key: $0, seconds: seconds[$0] ?? 0, visits: opens[$0] ?? 0, appName: usage.appNames[ActivityKey.identifier($0)])
            }
            for entry in rows.sorted(by: UsageSort.time.areInIncreasingOrder) {
                let fields = [day, entry.isWeb ? "website" : "app", entry.title, entry.identifier,
                              categorization.category(of: entry.key).name,
                              String(format: "%.1f", entry.seconds / 60), String(entry.visits)]
                lines.append(fields.map(field).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a field that holds a comma, quote or line break (RFC 4180).
    static func field(_ text: String) -> String {
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
