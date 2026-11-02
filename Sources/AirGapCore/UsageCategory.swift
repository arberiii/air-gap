import Foundation

/// A kind of activity, like Social or Productivity, that screen time is totaled by.
public struct UsageCategory: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Index into the view's fixed palette, picked once so deleting a category never recolors the others.
    public var colorIndex: Int

    public init(id: String, name: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
    }
}

/// Which category every app and site is in. Like `UsageGrouping`, only the display uses it.
/// A key's category is the user's choice, else the assistant's label, else the built-in table, else Other.
public struct Categorization: Codable, Equatable, Sendable {
    public static let paletteSize = 10
    public static let otherID = "other"
    public static let starter: [UsageCategory] = [
        ("social", "Social"), ("video", "Video & Entertainment"), ("productivity", "Productivity"),
        ("communication", "Communication"), ("news", "News & Reading"), ("shopping", "Shopping"),
        ("games", "Games"), (otherID, "Other"),
    ].enumerated().map { UsageCategory(id: $1.0, name: $1.1, colorIndex: $0) }

    public var categories: [UsageCategory] = starter
    /// Key (`web:<host>` or `app:<bundle id>`) -> category id, set from the row's menu.
    public var userLabels: [String: String] = [:]
    /// Key -> category id, from the assistant.
    public var assistantLabels: [String: String] = [:]
    /// Keys already sent to the assistant, so ones it couldn't label aren't asked again.
    public var asked: Set<String> = []
    /// Keys sent to the assistant whose answer hasn't arrived. Not saved: an answer only lands while its request is pending,
    /// so one arriving after everything was deleted is dropped.
    public private(set) var pending: Set<String> = []

    private enum CodingKeys: String, CodingKey { case categories, userLabels, assistantLabels = "claudeLabels", asked }

    public init() {}

    // Hand-written so a missing field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decodeIfPresent([UsageCategory].self, forKey: .categories) ?? Self.starter
        if !categories.contains(where: { $0.id == Self.otherID }) { categories.append(Self.starter.last!) }
        userLabels = try c.decodeIfPresent([String: String].self, forKey: .userLabels) ?? [:]
        assistantLabels = try c.decodeIfPresent([String: String].self, forKey: .assistantLabels) ?? [:]
        asked = try c.decodeIfPresent(Set<String>.self, forKey: .asked) ?? []
    }

    public func categoryID(of key: String) -> String {
        let known = { (id: String?) in id.flatMap { id in categories.contains { $0.id == id } ? id : nil } }
        return known(userLabels[key]) ?? known(assistantLabels[key]) ?? known(Self.builtInID(for: key)) ?? Self.otherID
    }

    public func category(of key: String) -> UsageCategory {
        let id = categoryID(of: key)
        return categories.first { $0.id == id } ?? categories.first { $0.id == Self.otherID } ?? Self.starter.last!
    }

    /// True for a key nothing has labeled yet and the assistant hasn't been asked about.
    public func needsLabel(_ key: String) -> Bool {
        userLabels[key] == nil && assistantLabels[key] == nil && Self.builtInID(for: key) == nil && !asked.contains(key)
    }

    public mutating func setUserCategory(_ id: String, for keys: [String]) {
        guard categories.contains(where: { $0.id == id }) else { return }
        for key in keys { userLabels[key] = id }
    }

    @discardableResult
    public mutating func addCategory(named name: String) -> UsageCategory? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let used = Set(categories.map(\.colorIndex))
        let color = (0..<Self.paletteSize).first { !used.contains($0) } ?? categories.count % Self.paletteSize
        let category = UsageCategory(id: UUID().uuidString, name: name, colorIndex: color)
        categories.append(category)
        return category
    }

    public mutating func renameCategory(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[i].name = name
    }

    /// Removes a category and every label pointing at it, so its items fall back to the next match. Other can't be deleted.
    public mutating func deleteCategory(_ id: String) {
        guard id != Self.otherID else { return }
        categories.removeAll { $0.id == id }
        userLabels = userLabels.filter { $0.value != id }
        assistantLabels = assistantLabels.filter { $0.value != id }
    }

    public mutating func beginLabeling(_ keys: [String]) { pending.formUnion(keys) }

    /// Saves the assistant's answer for keys still pending and marks them asked, so ones it skipped aren't sent again.
    public mutating func applyAssistantLabels(_ labels: [String: String], asked keys: [String]) {
        let keys = Set(keys).intersection(pending)
        pending.subtract(keys)
        assistantLabels.merge(labels.filter { keys.contains($0.key) }) { _, new in new }
        asked.formUnion(keys)
    }

    /// A failed request: the keys can be sent again later.
    public mutating func cancelLabeling(_ keys: [String]) { pending.subtract(keys) }

    /// Drops every label for an item removed from the log.
    public mutating func forget(key: String) {
        userLabels[key] = nil
        assistantLabels[key] = nil
        asked.remove(key)
        pending.remove(key)
    }

    /// Hosts match the entry or any subdomain of it; apps match by exact bundle id.
    static func builtInID(for key: String) -> String? {
        let value = ActivityKey.identifier(key)
        guard ActivityKey.isWeb(key) else { return ActivityKey.isApp(key) ? builtIn[value] : nil }
        var host = Substring(value)
        while true {
            if let id = builtIn[String(host)] { return id }
            guard let dot = host.firstIndex(of: ".") else { return nil }
            host = host[host.index(after: dot)...]
        }
    }

    static let builtIn: [String: String] = {
        let table: [String: [String]] = [
            "social": [
                "facebook.com", "instagram.com", "x.com", "twitter.com", "reddit.com", "tiktok.com", "linkedin.com", "threads.net",
                "bsky.app", "mastodon.social", "pinterest.com", "tumblr.com", "snapchat.com", "news.ycombinator.com", "quora.com",
            ],
            "video": [
                "youtube.com", "netflix.com", "twitch.tv", "hulu.com", "disneyplus.com", "primevideo.com", "max.com", "vimeo.com",
                "spotify.com", "music.apple.com", "soundcloud.com", "crunchyroll.com", "tv.apple.com",
                "com.spotify.client", "com.apple.TV", "com.apple.Music", "com.netflix.Netflix", "org.videolan.vlc", "com.apple.podcasts",
            ],
            "productivity": [
                "github.com", "gitlab.com", "linear.app", "notion.so", "figma.com", "docs.google.com", "drive.google.com",
                "sheets.google.com", "calendar.google.com", "atlassian.net", "trello.com", "asana.com", "stackoverflow.com",
                "vercel.com", "cloudflare.com", "aws.amazon.com", "claude.ai", "chatgpt.com", "developer.apple.com",
                "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
                "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.figma.Desktop", "notion.id", "com.linear",
                "com.anthropic.claudefordesktop", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
                "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.Notes", "md.obsidian",
                "com.apple.finder", "com.jetbrains.intellij", "com.sublimetext.4",
            ],
            "communication": [
                "mail.google.com", "outlook.live.com", "outlook.office.com", "slack.com", "discord.com", "web.whatsapp.com",
                "messenger.com", "telegram.org", "web.telegram.org", "zoom.us", "meet.google.com", "teams.microsoft.com",
                "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                "us.zoom.xos", "com.microsoft.teams2", "com.apple.mail", "com.apple.MobileSMS", "com.apple.FaceTime",
                "com.readdle.smartemail-Mac", "com.superhuman.electron",
            ],
            "news": [
                "nytimes.com", "theguardian.com", "bbc.com", "bbc.co.uk", "cnn.com", "washingtonpost.com", "reuters.com",
                "apnews.com", "bloomberg.com", "ft.com", "wsj.com", "theverge.com", "arstechnica.com", "medium.com",
                "substack.com", "wikipedia.org", "economist.com", "com.apple.news", "com.reederapp.5.macOS",
            ],
            "shopping": [
                "amazon.com", "amazon.co.uk", "amazon.de", "ebay.com", "etsy.com", "aliexpress.com", "temu.com", "walmart.com",
                "target.com", "bestbuy.com", "ikea.com", "zalando.com",
            ],
            "games": [
                "store.steampowered.com", "steamcommunity.com", "epicgames.com", "chess.com", "lichess.org", "roblox.com",
                "com.valvesoftware.steam", "com.blizzard.bnetlauncher", "com.apple.Chess",
            ],
        ]
        var result: [String: String] = [:]
        for (id, keys) in table { for key in keys { result[key] = id } }
        return result
    }()
}
