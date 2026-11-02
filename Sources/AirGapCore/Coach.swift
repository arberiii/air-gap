import Foundation

/// What the coach suggests before a session starts.
public struct CoachPlan: Codable, Equatable, Sendable {
    public var steps: [String]
    public var firstMove: String
    /// The whole focus list the work needs, not only additions.
    public var sites: [String]
    /// Bundle ids, picked from the apps the user was shown.
    public var apps: [String]
    public var encouragement: String
}

/// A minimal focus list the coach proposes for one session. Nothing changes until the user applies it.
public struct FocusProposal: Codable, Equatable, Sendable {
    public var sites: [String]
    public var apps: [FocusApp]
    /// `web:<host>` or `app:<bundle id>` keys the user unticked.
    public var skipped: Set<String> = []

    public init(sites: [String], apps: [FocusApp]) {
        self.sites = sites
        self.apps = apps
    }

    public var isEmpty: Bool { sites.isEmpty && apps.isEmpty }
    public var chosenSites: [String] { sites.filter { !skipped.contains("web:" + $0) } }
    public var chosenApps: [FocusApp] { apps.filter { !skipped.contains("app:" + $0.bundleID) } }
}

/// What the coach says after a session ends.
public struct CoachReflection: Codable, Equatable, Sendable {
    public var reflection: String
    public var nextIntention: String
}

/// The assistant's read of the user's screen time over a period.
public struct CoachUsageSummary: Codable, Equatable, Sendable {
    public enum Trend: String, Codable, Sendable {
        case better, same, worse, unclear

        public var label: String {
            switch self {
            case .better: return "More productive"
            case .same: return "About the same"
            case .worse: return "Less productive"
            case .unclear: return "Not enough data yet"
            }
        }
    }

    public var headline: String
    public var trend: Trend
    public var productivity: String
    public var patterns: [String]
    public var suggestion: String
}

/// The assistant's pick of a category for each app and site it was shown.
public struct CoachCategoryAnswer: Codable, Equatable, Sendable {
    public struct Label: Codable, Equatable, Sendable {
        public var key: String
        public var category: String

        public init(key: String, category: String) {
            self.key = key
            self.category = category
        }
    }

    public var labels: [Label]

    public init(labels: [Label]) { self.labels = labels }
}

/// The assistant's answer to a request to open one blocked page.
public struct CoachPageVerdict: Codable, Equatable, Sendable {
    public var approve: Bool
    public var reply: String

    public init(approve: Bool, reply: String) {
        self.approve = approve
        self.reply = reply
    }
}

public enum CoachError: Error, Equatable, LocalizedError {
    case notInstalled
    case failed(String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "The assistant is not installed. Install Claude Code or Codex, then try again."
        case .failed(let message): return message.isEmpty ? "The assistant did not answer." : message
        case .unreadable: return "The assistant's answer could not be read."
        }
    }
}

/// Builds prompts for the `claude` and `codex` commands and reads their answers. Kept free of process handling so it can be tested.
public enum Coach {
    public static let systemPrompt = """
    You are the focus coach inside AirGap, a macOS app that blocks distractions during deliberate focus sessions. \
    The user struggles with motivation, follow-through and making room for creative, thoughtful work. \
    Be warm, concrete and brief. Never lecture, never use productivity jargon, never invent facts about the user. \
    Base patterns only on the data you are given. Answer only through the requested structured output.
    """

    public static let planSchema = """
    {"type":"object","additionalProperties":false,"required":["steps","firstMove","sites","apps","encouragement"],"properties":{\
    "steps":{"type":"array","minItems":2,"maxItems":5,"items":{"type":"string"},"description":"Concrete steps that fit the session length, in order. Each under 90 characters, starting with a verb."},\
    "firstMove":{"type":"string","description":"The smallest action that takes under two minutes and gets the session going. Under 90 characters."},\
    "sites":{"type":"array","maxItems":8,"items":{"type":"string"},"description":"The smallest set of bare domains (like docs.google.com) this work needs. Prefer sites from the user's recent usage. Include sites from the current focus list only if this work needs them. Never include sites they were pulled toward, social media, news or video unless the work is about them."},\
    "apps":{"type":"array","maxItems":6,"items":{"type":"string"},"description":"Bundle ids, copied exactly from the apps listed in the prompt, of the apps this work needs. Leave out chat, social, games and anything not needed for this work. Finder and browsers are always allowed, so never list them."},\
    "encouragement":{"type":"string","description":"One or two sentences that connect this session to the bigger goal, or name a pattern from their history. Under 220 characters."}}}
    """

    public static let reflectionSchema = """
    {"type":"object","additionalProperties":false,"required":["reflection","nextIntention"],"properties":{\
    "reflection":{"type":"string","description":"Two to four short sentences: what went well, one honest pattern from the data, one concrete suggestion for the next session. Under 450 characters."},\
    "nextIntention":{"type":"string","description":"A suggested intention for the next session, phrased as the user would write it. Under 100 characters."}}}
    """

    public static let usageSummarySchema = """
    {"type":"object","additionalProperties":false,"required":["headline","trend","productivity","patterns","suggestion"],"properties":{\
    "headline":{"type":"string","description":"One sentence that sums up where the time went. Under 120 characters."},\
    "trend":{"type":"string","enum":["better","same","worse","unclear"],"description":"Whether this period was more productive than the one before it. unclear when there is too little data to compare."},\
    "productivity":{"type":"string","description":"Two or three short sentences on how productive this period was compared with the one before, citing numbers from the data. Treat blocked items and sites the user was pulled toward as distractions and focus list items as work. Under 400 characters."},\
    "patterns":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"string"},"description":"Concrete patterns seen in the data, like which apps eat the most time, frequent reopening, busy days, or focus session follow-through. Each under 140 characters."},\
    "suggestion":{"type":"string","description":"One concrete, small change to try next, based on the patterns. Under 180 characters."}}}
    """

    public static let pageVerdictSchema = """
    {"type":"object","additionalProperties":false,"required":["approve","reply"],"properties":{\
    "approve":{"type":"boolean","description":"true only when this exact page plausibly serves the reason given, and the reason is specific. Vague reasons like 'just checking' or 'need it' are false."},\
    "reply":{"type":"string","description":"One short sentence to the user: why it is fine to open, or why not and what to do instead. Under 140 characters."}}}
    """

    /// Asks whether one blocked page may open for a few minutes. `focus` is the session's intention, or `nil` outside a session.
    public static func pagePassPrompt(url: URL, title: String?, reason: String, blockedBecause: String, focus: String?,
                                      earlier: [PagePass], minutes: Int = PagePass.minutes) -> String {
        var what = ["A page I opened was blocked. \(blockedBecause)", "Page: \(url.absoluteString)"]
        if let title, !title.isEmpty { what.append("Page title: \(title)") }
        return passPrompt(what: what, reason: reason, focus: focus, earlier: earlier, rule:
            "If you approve, only this one page opens, for \(minutes) minutes; the rest of the site stays blocked. "
            + "Approve when the page plausibly serves a specific, concrete need that matches the reason" + (focus == nil ? "." : " and my focus.")
            + " Decline vague reasons, feeds, home pages and anything that looks like browsing for its own sake.")
    }

    /// Asks whether one blocked app may open for a few minutes. `focus` is the session's intention, or `nil` outside a session.
    public static func appPassPrompt(appName: String, bundleID: String, reason: String, blockedBecause: String, focus: String?,
                                     earlier: [PagePass], minutes: Int = PagePass.minutes) -> String {
        passPrompt(what: ["An app I opened was blocked. \(blockedBecause)", "App: \(appName) (\(bundleID))"],
                   reason: reason, focus: focus, earlier: earlier, rule:
            "If you approve, the app opens for \(minutes) minutes, then it's hidden again. "
            + "Approve when the app plausibly serves a specific, concrete task that matches the reason" + (focus == nil ? "." : " and my focus.")
            + " Decline vague reasons and anything that looks like scrolling, chatting or playing for its own sake.")
    }

    private static func passPrompt(what: [String], reason: String, focus: String?, earlier: [PagePass], rule: String) -> String {
        var lines = what
        if let focus { lines.append("I'm in a focus session. What I set out to do: \(focus)") }
        lines.append("Why I want to open it: \(reason)")
        if !earlier.isEmpty {
            lines.append("Pages and apps I asked for earlier today: "
                         + earlier.suffix(5).map { "\($0.title.map { "\($0) " } ?? "")\($0.page) (\($0.approved ? "approved" : "declined"))" }.joined(separator: ", "))
        }
        lines.append(rule)
        return lines.joined(separator: "\n")
    }

    public static func categorySchema(ids: [String]) -> String {
        let idList = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"type":"object","additionalProperties":false,"required":["labels"],"properties":{\
        "labels":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["key","category"],"properties":{\
        "key":{"type":"string","description":"The item's key, copied exactly from the prompt."},\
        "category":{"type":"string","enum":[\(idList)],"description":"The id of the category that fits the item best."}}}}}}
        """
    }

    /// Asks the assistant to sort apps and sites into categories. Only names go in, never how long they were used.
    public static func categoryPrompt(items: [(key: String, name: String)], categories: [UsageCategory]) -> String {
        var lines = [
            "Put each app and website below into the category that fits it best, by what people mostly use it for.",
            "Use other only when nothing else fits. Answer for every item, copying its key exactly.",
            "Categories (id: name):",
        ]
        lines += categories.map { "- \($0.id): \($0.name)" }
        lines.append("Items (key — name; web: keys are websites, app: keys are macOS bundle ids):")
        lines += items.map { "- \($0.key) — \($0.name)" }
        return lines.joined(separator: "\n")
    }

    /// The assistant's labels, keeping only keys it was asked about and categories that exist.
    public static func categoryLabels(_ answer: CoachCategoryAnswer, asked: [String], validIDs: Set<String>) -> [String: String] {
        let asked = Set(asked)
        var result: [String: String] = [:]
        for label in answer.labels where asked.contains(label.key) && validIDs.contains(label.category) { result[label.key] = label.category }
        return result
    }

    /// Screen time for the `days` ending on `now`, compared with the same number of days before them.
    public static func usageSummaryPrompt(usage: UsageLog, days: Int, rules: [BlockRule], allowlist: [String], focusApps: [FocusApp],
                                          history: [FocusSession], grouping: UsageGrouping = UsageGrouping(), excludedApps: Set<String> = [],
                                          now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = max(days, 1)
        let grouped = { (entries: [UsageEntry]) in grouping.apply(entries, appNames: usage.appNames, excludedApps: excludedApps) }
        let current = grouped(usage.totals(lastDays: days, endingOn: now, calendar: calendar))
        let previousEnd = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let previous = grouped(usage.totals(lastDays: days, endingOn: previousEnd, calendar: calendar))
        let previousByKey = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let total = { (entries: [UsageEntry]) in Formatting.duration(entries.reduce(0) { $0 + $1.seconds }) }
        let opens = { (entries: [UsageEntry]) in entries.reduce(0) { $0 + $1.visits } }
        let period = days == 1 ? "today" : "the last \(days) days"
        let before = days == 1 ? "yesterday" : "the \(days) days before"
        var lines = [
            "Summarize my screen time for \(period) and tell me how productive I've been compared with \(before).",
            "Local time: \(timeString(now))",
            "Total for \(period): \(total(current)), \(opens(current)) opens. For \(before): \(total(previous)), \(opens(previous)) opens.",
            "Daily totals, oldest first: " + usage.dailyTotals(lastDays: 14, endingOn: now, calendar: calendar)
                .map { "\(dateString($0.day, format: "EEE d MMM")) \(Formatting.duration($0.seconds))" }.joined(separator: ", "),
        ]
        if current.isEmpty {
            lines.append("No screen time was logged for \(period).")
        } else {
            lines.append("Where the time went in \(period) (time, opens; then \(before)):")
            lines += current.prefix(20).map { entry in
                let old = previousByKey[entry.key]
                let kind = entry.isGroup ? " (" + entry.members.map { $0.isWeb ? $0.title : "app" }.joined(separator: " + ") + ")" : entry.isWeb ? "" : " (app)"
                return "- \(entry.title)\(kind): \(Formatting.duration(entry.seconds)), \(entry.visits) opens; " +
                    (old.map { "\(Formatting.duration($0.seconds)), \($0.visits) opens" } ?? "not used")
            }
        }
        let dropped = previous.filter { old in !current.contains { $0.key == old.key } }.prefix(5)
        if !dropped.isEmpty {
            lines.append("Used \(before) but not in \(period): " + dropped.map { "\($0.title) \(Formatting.duration($0.seconds))" }.joined(separator: ", "))
        }
        if !rules.isEmpty {
            lines.append("On my block list (things I consider distractions): " + rules.map { rule in
                rule.displayName + (rule.dailyLimitMinutes.map { " (\($0) min/day allowed)" } ?? "")
            }.joined(separator: ", "))
        }
        let work = allowlist + focusApps.map(\.name)
        if !work.isEmpty { lines.append("On my focus list (things I use for work): " + work.joined(separator: ", ")) }
        let start = calendar.date(byAdding: .day, value: -(2 * days - 1), to: calendar.startOfDay(for: now)) ?? now
        let sessions = history.filter { $0.startedAt >= start }
        if sessions.isEmpty {
            lines.append("No focus sessions in \(period) or \(before).")
        } else {
            lines.append("Focus sessions in \(period) and \(before), oldest first:")
            lines += sessions.suffix(12).map { session in
                let length = session.duration.map(Formatting.duration) ?? "unfinished"
                let line = "- \(dateString(session.startedAt)), planned \(session.plannedMinutes) min, lasted \(length): \"\(session.intention)\" → \(session.outcome?.label ?? "no check-in")"
                return line + pulledTowardLine(session, appNames: usage.appNames)
            }
        }
        lines.append("Find the patterns, judge honestly whether I'm becoming more productive, and suggest one small change.")
        return lines.joined(separator: "\n")
    }

    /// - Parameter recent: usage over the last days, used to propose the apps and sites the work needs.
    public static func planPrompt(intention: String, minutes: Int, allowlist: [String], focusApps: [FocusApp] = [], history: [FocusSession],
                                  todayTop: [UsageEntry], recent: [UsageEntry] = [], theme: FocusTheme? = nil, appNames: [String: String] = [:],
                                  now: Date = Date()) -> String {
        var lines = themeLines(theme) + [
            "I'm about to start a \(minutes)-minute focus session.",
            "What I want to get done: \(intention)",
            "My focus list from last time, which may not fit this work: sites \(allowlist.isEmpty ? "none" : allowlist.joined(separator: ", ")); apps \(focusApps.isEmpty ? "none" : focusApps.map(\.name).joined(separator: ", "))",
            "Local time: \(timeString(now))",
        ]
        if !todayTop.isEmpty {
            lines.append("Where my screen time went today so far: " + todayTop.prefix(6).map { "\($0.title) \(Formatting.duration($0.seconds))" }.joined(separator: ", "))
        }
        let apps = recent.filter { !$0.isWeb }.prefix(25), sites = recent.filter(\.isWeb).prefix(25)
        if !apps.isEmpty {
            lines.append("Apps I used recently (bundle id = name, time): " + apps.map { "\($0.identifier) = \($0.title), \(Formatting.duration($0.seconds))" }.joined(separator: "; "))
        }
        if !sites.isEmpty {
            lines.append("Sites I used recently: " + sites.map { "\($0.identifier) \(Formatting.duration($0.seconds))" }.joined(separator: ", "))
        }
        lines.append(contentsOf: historyLines(history, appNames: appNames))
        if theme?.kind == .reading {
            lines.append("This is reading time with a hard stop, so make the steps what to look for or read, not tasks. Give me a first move, propose the smallest set of apps and sites this needs, and help me start.")
        } else {
            lines.append("Break this session into steps, give me a first move, propose the smallest set of apps and sites this work needs, and help me start.")
        }
        return lines.joined(separator: "\n")
    }

    public static func reflectionPrompt(session: FocusSession, appNames: [String: String], history: [FocusSession],
                                        theme: FocusTheme? = nil, pagePasses: [PagePass] = []) -> String {
        let s = session.summary(appNames: appNames)
        let actual = session.duration ?? 0
        var lines = themeLines(theme) + [
            "I just finished a focus session.",
            "What I set out to do: \(session.intention)",
            "Planned: \(session.plannedMinutes) min. Session lasted: \(Formatting.duration(actual)). Active screen time: \(Formatting.duration(s.totalSeconds)).",
            "On my focus list (sites and apps): \(Formatting.duration(s.focusListSeconds)). Other websites: \(Formatting.duration(s.otherWebSeconds)). Other apps: \(Formatting.duration(s.appSeconds)).",
            "Times I tried to open a blocked site or app: \(s.blockedAttempts)" + (session.blockedAttempts.isEmpty ? "" : " (" + session.pulledToward(appNames: appNames).prefix(4).map { "\($0.name) ×\($0.count)" }.joined(separator: ", ") + ")"),
        ]
        if !pagePasses.isEmpty {
            lines.append("Blocked pages I asked to open: " + pagePasses.map { "\($0.page) because \"\($0.reason)\" (\($0.approved ? "approved" : "declined"))" }.joined(separator: "; "))
        }
        if !s.top.isEmpty { lines.append("Most time went to: " + s.top.map { "\($0.name) \(Formatting.duration($0.seconds))" }.joined(separator: ", ")) }
        if !session.steps.isEmpty {
            lines.append("Steps: " + session.steps.map { ($0.done ? "[done] " : "[open] ") + $0.text }.joined(separator: "; "))
        }
        if let outcome = session.outcome { lines.append("Did I move it forward? \(outcome.label)") }
        if let note = session.note, !note.isEmpty { lines.append("My note: \(note)") }
        if let next = session.nextTime, !next.isEmpty { lines.append("Note for next time: \(next)") }
        lines.append(contentsOf: historyLines(history.filter { $0.id != session.id }, appNames: appNames))
        if theme?.kind == .reading {
            lines.append("Reflect on my pacing, whether I stopped on time, and help me keep one takeaway from what I read.")
        } else {
            lines.append("Reflect on this session with me and suggest what to focus on next.")
        }
        return lines.joined(separator: "\n")
    }

    private static func themeLines(_ theme: FocusTheme?) -> [String] {
        guard let theme else { return [] }
        let kind = theme.kind == .reading ? "a reading theme with a hard time cap" : "a recurring chore"
        return ["This is a run of my theme \"\(theme.name)\", \(kind). The past sessions below are earlier runs of it."]
    }

    /// The theme's checklist first, then the planned steps it doesn't already have.
    public static func mergeSteps(checklist: [String], planned: [String]) -> [String] {
        var result: [String] = [], seen = Set<String>()
        for step in checklist + planned {
            let text = step.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
        }
        return result
    }

    private static func historyLines(_ history: [FocusSession], appNames: [String: String]) -> [String] {
        let recent = history.suffix(6)
        guard !recent.isEmpty else { return ["This is my first focus session in AirGap."] }
        return ["My recent sessions, oldest first:"] + recent.map { session in
            var line = "- \(dateString(session.startedAt)), \(session.plannedMinutes) min: \"\(session.intention)\" → \(session.outcome?.label ?? "no check-in")"
            if let note = session.note, !note.isEmpty { line += ". Note: \(note)" }
            if let next = session.nextTime, !next.isEmpty { line += ". Note for next time: \(next)" }
            return line + pulledTowardLine(session, appNames: appNames)
        }
    }

    /// ". Pulled toward: …" with the session's three most frequent distractions, or nothing.
    private static func pulledTowardLine(_ session: FocusSession, appNames: [String: String]) -> String {
        let names = session.pulledToward(appNames: appNames).prefix(3).map(\.name)
        return names.isEmpty ? "" : ". Pulled toward: " + names.joined(separator: ", ")
    }

    /// Keeps only suggested sites that are real hosts, not on the focus list yet, and not ones the user blocks or got distracted by.
    public static func usableSites(_ sites: [String], allowlist: [String], rules: [BlockRule], history: [FocusSession]) -> [String] {
        let distractions = Set(history.flatMap { $0.blockedAttempts.keys.filter(ActivityKey.isWeb).map(ActivityKey.identifier) })
        var result: [String] = []
        for host in sites.compactMap({ URLNormalizer.host(from: $0) }) where !result.contains(host) {
            let probe = ActivityContext(bundleID: "", appName: "", url: URL(string: "https://\(host)/"))
            if allowlist.contains(where: { URLNormalizer.host(host, isWithin: $0) }) { continue }
            if rules.contains(where: { $0.kind == .site && $0.matches(probe) }) { continue }
            if distractions.contains(where: { URLNormalizer.host(host, isWithin: $0) || URLNormalizer.host($0, isWithin: host) }) { continue }
            result.append(host)
        }
        return result
    }

    /// Turns the coach's picks into a proposal: sites as in `usableSites`, apps only those the user actually has
    /// (seen in `known`), never always-allowed ones, blocked ones, or ones the user was pulled toward.
    public static func proposal(from plan: CoachPlan, known: [FocusApp], alwaysAllowed: Set<String>, rules: [BlockRule],
                                history: [FocusSession]) -> FocusProposal {
        let distractions = Set(history.flatMap { $0.blockedAttempts.keys })
        var apps: [FocusApp] = []
        for id in plan.apps {
            guard let app = known.first(where: { $0.bundleID == id }), !apps.contains(app), !alwaysAllowed.contains(id),
                  !distractions.contains(ActivityKey.app(id)),
                  !rules.contains(where: { $0.kind == .app && $0.value == id }) else { continue }
            apps.append(app)
        }
        return FocusProposal(sites: usableSites(plan.sites, allowlist: [], rules: rules, history: history), apps: apps)
    }

    /// Reads the JSON printed by `claude -p --output-format json --json-schema ...`.
    public static func decode<T: Decodable>(_ type: T.Type, from output: Data) throws -> T {
        guard let envelope = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw CoachError.unreadable }
        if envelope["is_error"] as? Bool == true { throw CoachError.failed((envelope["result"] as? String) ?? "") }
        if let structured = envelope["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        guard let text = envelope["result"] as? String else { throw CoachError.unreadable }
        return try decode(type, fromText: text)
    }

    /// Reads a JSON answer given as plain text, like the last message `codex exec --output-schema ...` writes, with or without a code fence.
    public static func decode<T: Decodable>(_ type: T.Type, fromText text: String) throws -> T {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        guard let value = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else { throw CoachError.unreadable }
        return value
    }

    /// The reason `codex exec` failed, from its stderr: the message of its last `ERROR:` line, else its last line.
    public static func codexError(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let line = lines.last(where: { $0.hasPrefix("ERROR:") }) else { return lines.last ?? "" }
        let detail = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        if let json = try? JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String ?? json["message"] as? String {
            return message
        }
        return detail
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE HH:mm"; return f.string(from: date)
    }

    private static func dateString(_ date: Date, format: String = "EEE d MMM HH:mm") -> String {
        let f = DateFormatter(); f.dateFormat = format; return f.string(from: date)
    }
}
