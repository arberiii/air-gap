import Foundation

/// Which apps and sites the screen time list shows as one row, like the Claude app and claude.ai.
/// Only the display is grouped: the log, block rules and daily limits still see each app and site on its own.
public struct UsageGrouping: Codable, Equatable, Sendable {
    /// Member key -> the key its group is shown as, set with "Group with…".
    public var joined: [String: String] = [:]
    /// Sites the user split from the app they were matched with automatically.
    public var separated: Set<String> = []

    public init() {}

    /// The key `key` is shown under. Sites join an app with the same name unless the user separated them.
    /// - Parameters:
    ///   - appNames: bundle id -> name of every app seen, so matches stay the same from day to day.
    ///   - excludedApps: bundle ids never matched automatically, like browsers.
    public func primary(of key: String, appNames: [String: String], excludedApps: Set<String> = []) -> String {
        var result = joined[key] ?? automatic(key, appNames: appNames, excludedApps: excludedApps) ?? key
        // The matched app may itself be grouped into another row.
        for _ in 0..<4 { guard let next = joined[result], next != result else { break }; result = next }
        return result
    }

    private func automatic(_ key: String, appNames: [String: String], excludedApps: Set<String>) -> String? {
        guard ActivityKey.isWeb(key), !separated.contains(key) else { return nil }
        let host = ActivityKey.identifier(key)
        return appNames
            .filter { !excludedApps.contains($0.key) && Self.matches(appName: $0.value, host: host) }
            .map(\.key).sorted().first.map(ActivityKey.app)
    }

    /// Folds members into one row per group, summing time and opens, sorted again by `order`.
    public func apply(_ entries: [UsageEntry], appNames: [String: String], excludedApps: Set<String> = [],
                      sortedBy order: UsageSort = .time) -> [UsageEntry] {
        var groups: [String: [UsageEntry]] = [:], firstSeen: [String] = []
        for entry in entries {
            let key = primary(of: entry.key, appNames: appNames, excludedApps: excludedApps)
            if groups[key] == nil { firstSeen.append(key) }
            groups[key, default: []].append(entry)
        }
        let rows = firstSeen.map { key -> UsageEntry in
            let members = groups[key] ?? []
            guard members.count > 1 || members.first?.key != key else { return members[0] }
            var row = UsageEntry(key: key, seconds: members.reduce(0) { $0 + $1.seconds }, visits: members.reduce(0) { $0 + $1.visits },
                                 appName: appNames[ActivityKey.identifier(key)])
            row.members = members.sorted { $0.seconds > $1.seconds }
            return row
        }
        return rows.sorted(by: order.areInIncreasingOrder)
    }

    /// Shows `key` (and anything already grouped under it) as part of `target`'s row. An app is preferred as the row's name.
    public mutating func group(_ key: String, with target: String, appNames: [String: String], excludedApps: Set<String> = []) {
        let a = primary(of: key, appNames: appNames, excludedApps: excludedApps)
        let b = primary(of: target, appNames: appNames, excludedApps: excludedApps)
        guard a != b else { return }
        let (head, other) = ActivityKey.isApp(a) && !ActivityKey.isApp(b) ? (a, b) : (b, a)
        for (member, to) in joined where to == other { joined[member] = head }
        joined[other] = head
        joined[head] = nil
        separated.remove(other)
    }

    /// Splits every member out of the group shown as `key`, so each gets its own row again.
    public mutating func separate(_ group: UsageEntry) {
        for member in group.members where member.key != group.key {
            joined[member.key] = nil
            if member.isWeb { separated.insert(member.key) }
        }
    }

    /// True when the site's name is the app's name, like Slack and app.slack.com or Claude and claude.ai.
    public static func matches(appName: String, host: String) -> Bool {
        guard let label = siteName(host), label.count >= 3 else { return false }
        var name = appName.lowercased()
        if let dot = name.firstIndex(of: "."), !name.contains(" ") { name = String(name[..<dot]) } // "zoom.us"
        var words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        while words.count > 1, let last = words.last, ["app", "desktop", "beta", "nightly", "canary", "preview", "for"].contains(last) {
            words.removeLast()
            if words.last == "for" { words.removeLast() }
        }
        return words.joined() == label
    }

    /// "slack" for app.slack.com, "bbc" for bbc.co.uk.
    static func siteName(_ host: String) -> String? {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        if parts.count >= 3, parts[parts.count - 1].count == 2, secondLevel.contains(parts[parts.count - 2]) { return parts[parts.count - 3] }
        return parts[parts.count - 2]
    }
}
