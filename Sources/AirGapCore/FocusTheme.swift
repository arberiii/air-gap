import Foundation

/// Chores are about getting through the work; reading is about stopping on time and keeping a takeaway.
public enum ThemeKind: String, Codable, CaseIterable, Sendable {
    case chore, reading
}

/// A saved kind of session that comes back, like daily Linear triage or reading the news.
public struct FocusTheme: Codable, Identifiable, Equatable, Sendable {
    public static let lengthOptions = [15, 30, 60, 120, 480]

    public var id: UUID
    public var name: String
    public var kind: ThemeKind
    public var minutes: Int
    /// Prefilled into the intention field each run.
    public var intention: String
    /// Copied into the session's steps each run.
    public var checklist: [String]
    public var sites: [String]
    public var apps: [FocusApp]

    public init(id: UUID = UUID(), name: String, kind: ThemeKind, minutes: Int, intention: String, checklist: [String],
                sites: [String], apps: [FocusApp]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.minutes = minutes
        self.intention = intention
        self.checklist = checklist
        self.sites = sites
        self.apps = apps
    }
}

/// How long a theme's runs take, recent ones against earlier ones.
public struct ThemeTrend: Equatable, Sendable {
    public var averageSeconds: TimeInterval
    /// The last three runs.
    public var recentAverageSeconds: TimeInterval
    /// The runs before those, or nil when there are none.
    public var earlierAverageSeconds: TimeInterval?
}

/// Lookups over session history for one theme.
public enum ThemeHistory {
    /// The theme's runs, newest first.
    public static func runs(of themeID: UUID, in history: [FocusSession]) -> [FocusSession] {
        history.filter { $0.themeID == themeID }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The most recent note left for the next run, skipping runs that left none.
    public static func lastNextTime(of themeID: UUID, in history: [FocusSession]) -> String? {
        runs(of: themeID, in: history).lazy
            .compactMap { $0.nextTime?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Nil with fewer than two finished runs.
    public static func trend(of themeID: UUID, in history: [FocusSession]) -> ThemeTrend? {
        let lengths = runs(of: themeID, in: history).reversed().compactMap(\.duration)
        guard lengths.count >= 2 else { return nil }
        let average = { (values: ArraySlice<TimeInterval>) in values.reduce(0, +) / Double(values.count) }
        let recent = lengths.suffix(3), earlier = lengths.dropLast(3)
        return ThemeTrend(averageSeconds: average(lengths[...]), recentAverageSeconds: average(recent),
                          earlierAverageSeconds: earlier.isEmpty ? nil : average(earlier))
    }

    /// Drops the oldest one-off sessions until at most `limit` remain. Themed runs are always kept.
    public static func trim(_ history: [FocusSession], keepingOneOff limit: Int) -> [FocusSession] {
        let excess = history.filter { $0.themeID == nil }.count - limit
        guard excess > 0 else { return history }
        let dropped = Set(history.filter { $0.themeID == nil }.sorted { $0.startedAt < $1.startedAt }.prefix(excess).map(\.id))
        return history.filter { !dropped.contains($0.id) }
    }
}
