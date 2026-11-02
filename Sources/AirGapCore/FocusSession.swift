import Foundation

/// An app the user allows during focus sessions.
public struct FocusApp: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// How a focus session went, answered by the user at the end.
public enum SessionOutcome: String, Codable, CaseIterable, Sendable {
    case done, partly, notReally

    public var label: String {
        switch self {
        case .done: return "Yes"
        case .partly: return "Partly"
        case .notReally: return "Not really"
        }
    }
}

public struct FocusStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var done: Bool

    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// One deliberate focus session: what the user set out to do, what actually happened, and how they rated it.
public struct FocusSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var intention: String
    public var plannedMinutes: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var steps: [FocusStep]
    /// The smallest action that gets the session going, suggested by the coach.
    public var firstMove: String?
    /// Active seconds per activity during the session, keyed like `UsageLog` (`web:<host>` / `app:<bundle id>`).
    public var activity: [String: TimeInterval]
    /// Times a site or app outside the focus list was redirected or hidden, keyed like `activity`.
    public var blockedAttempts: [String: Int]
    /// Hosts on the focus list when the session ran.
    public var allowlist: [String]
    /// Bundle ids of apps on the focus list when the session ran. Optional so a session without it still decodes.
    public var allowedApps: [String]?
    /// Apps and sites allowed for a few minutes, keyed like `activity`, with when the allowance ends.
    /// Ended allowances stay, since each app or site gets only one per session.
    public var allowedUntil: [String: Date]?
    /// The theme this session was a run of, and its kind at the time (kept if the theme is deleted).
    public var themeID: UUID?
    public var themeKind: ThemeKind?
    /// What the user wants to remember at the next run of the same theme.
    public var nextTime: String?
    public var outcome: SessionOutcome?
    public var note: String?
    public var reflection: String?

    public init(id: UUID = UUID(), intention: String, plannedMinutes: Int, startedAt: Date, steps: [FocusStep] = [],
                firstMove: String? = nil, allowlist: [String] = [], allowedApps: [String]? = nil) {
        self.id = id
        self.intention = intention
        self.plannedMinutes = plannedMinutes
        self.startedAt = startedAt
        self.steps = steps
        self.firstMove = firstMove
        self.activity = [:]
        self.blockedAttempts = [:]
        self.allowlist = allowlist
        self.allowedApps = allowedApps
    }

    public var nextStep: FocusStep? { steps.first { !$0.done } }
    public var isReading: Bool { themeKind == .reading }

    /// Whether the app (`app:<bundle id>`) or site (`web:<host>`) still has its one brief allowance this session.
    public func canAllowBriefly(key: String) -> Bool { allowedUntil?[key] == nil }

    /// Allows an app or site until `until`. Returns false when it already used its allowance this session.
    @discardableResult
    public mutating func allowBriefly(key: String, until: Date) -> Bool {
        guard canAllowBriefly(key: key) else { return false }
        allowedUntil = (allowedUntil ?? [:]).merging([key: until]) { $1 }
        return true
    }

    /// Bundle ids and hosts still allowed at `now`.
    public func brieflyAllowed(at now: Date = Date()) -> (apps: [String], hosts: [String]) {
        let keys = (allowedUntil ?? [:]).filter { $0.value > now }.keys
        return (keys.filter(ActivityKey.isApp).map(ActivityKey.identifier), keys.filter(ActivityKey.isWeb).map(ActivityKey.identifier))
    }

    public mutating func record(_ seconds: TimeInterval, key: String) {
        activity[key, default: 0] += seconds
    }

    /// Forgets one activity (`ActivityKey`).
    public mutating func remove(key: String) {
        activity[key] = nil
        blockedAttempts[key] = nil
    }

    /// Counts a redirect or hide of an app or site (`ActivityKey`).
    public mutating func recordBlocked(key: String) {
        blockedAttempts[key, default: 0] += 1
    }

    /// What the user was pulled toward, most often first, by display name: the host for sites, the app's name for apps.
    public func pulledToward(appNames: [String: String] = [:]) -> [(name: String, count: Int)] {
        blockedAttempts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { key, count in
            let id = ActivityKey.identifier(key)
            return (ActivityKey.isWeb(key) ? id : appNames[id] ?? id, count)
        }
    }

    /// How long the session ran, or nil while it hasn't ended.
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    /// Splits active time into time on the focus list (sites and apps), other websites and other apps.
    public func summary(appNames: [String: String] = [:]) -> SessionSummary {
        var onList: TimeInterval = 0
        var otherWeb: TimeInterval = 0
        var apps: TimeInterval = 0
        for (key, seconds) in activity {
            let id = ActivityKey.identifier(key)
            if ActivityKey.isWeb(key) {
                if allowlist.contains(where: { URLNormalizer.host(id, isWithin: $0) }) { onList += seconds } else { otherWeb += seconds }
            } else if allowedApps?.contains(id) == true {
                onList += seconds
            } else {
                apps += seconds
            }
        }
        let top = activity.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(5).map { key, seconds in
            let id = ActivityKey.identifier(key)
            return (name: ActivityKey.isWeb(key) ? id : (appNames[id] ?? id), seconds: seconds)
        }
        return SessionSummary(focusListSeconds: onList, otherWebSeconds: otherWeb, appSeconds: apps,
                              blockedAttempts: blockedAttempts.values.reduce(0, +), top: Array(top))
    }
}

public struct SessionSummary: Equatable, Sendable {
    public var focusListSeconds: TimeInterval
    public var otherWebSeconds: TimeInterval
    public var appSeconds: TimeInterval
    public var blockedAttempts: Int
    public var top: [(name: String, seconds: TimeInterval)]

    public var totalSeconds: TimeInterval { focusListSeconds + otherWebSeconds + appSeconds }

    public static func == (a: SessionSummary, b: SessionSummary) -> Bool {
        a.focusListSeconds == b.focusListSeconds && a.otherWebSeconds == b.otherWebSeconds && a.appSeconds == b.appSeconds
            && a.blockedAttempts == b.blockedAttempts && a.top.map(\.name) == b.top.map(\.name) && a.top.map(\.seconds) == b.top.map(\.seconds)
    }
}
