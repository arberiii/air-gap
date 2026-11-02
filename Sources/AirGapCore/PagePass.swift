import Foundation

/// One blocked page or app the user asked to open, with the reason they typed and the assistant's answer.
/// An approved pass lets only that page (or app) through until `until`; any other page on the site stays blocked.
public struct PagePass: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The page as `PagePass.page(from:)` normalized it, or `app:<bundle id>` for an app.
    public var page: String
    public var title: String?
    public var reason: String
    public var approved: Bool
    /// The assistant's one-line answer, shown to the user.
    public var reply: String
    public var askedAt: Date
    public var until: Date?

    public init(id: UUID = UUID(), page: String, title: String?, reason: String, approved: Bool, reply: String, askedAt: Date, until: Date?) {
        self.id = id
        self.page = page
        self.title = title
        self.reason = reason
        self.approved = approved
        self.reply = reply
        self.askedAt = askedAt
        self.until = until
    }

    public static let minutes = 15
    /// Approved passes per day, so asking doesn't turn into a new way to browse.
    public static let dailyLimit = 3
    /// The shortest reason worth sending to the assistant.
    public static let minReasonLength = 8

    /// Query parameters that only track where a link came from, so the same page shared twice still matches.
    private static let trackingParameters: Set<String> = ["fbclid", "gclid", "si", "ref", "ref_source", "ref_url", "share_id", "context", "rdt", "igsh", "mibextid"]
    /// Subdomains that show the same pages as the bare host, like `old.reddit.com`.
    private static let mirrorPrefixes = ["old.", "new.", "np.", "m.", "mobile.", "web."]

    /// `host/path?query` with mirror subdomains, tracking parameters, trailing slashes and fragments dropped.
    public static func page(from url: URL) -> String? {
        guard var host = URLNormalizer.host(from: url.absoluteString),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let prefix = mirrorPrefixes.first(where: { host.hasPrefix($0) }), host.dropFirst(prefix.count).contains(".") {
            host.removeFirst(prefix.count)
        }
        var path = parts.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        let items: [URLQueryItem] = (parts.percentEncodedQueryItems ?? nil) ?? []
        let query = items
            .filter { !$0.name.lowercased().hasPrefix("utm_") && !trackingParameters.contains($0.name.lowercased()) }
            .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }
            .sorted()
        return host + path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    public func isActive(at now: Date) -> Bool { approved && (until ?? .distantPast) > now }

    /// Same page, ignoring tracking parameters and mirror subdomains. Every other page, even on the same site, does not match.
    public func covers(_ url: URL) -> Bool { PagePass.page(from: url) == page }

    /// The `page` of a pass for an app.
    public static func app(_ bundleID: String) -> String { ActivityKey.app(bundleID) }
    public func covers(app bundleID: String) -> Bool { page == PagePass.app(bundleID) }

    /// Approved passes asked for on the same day as `now`.
    public static func approvedToday(_ passes: [PagePass], now: Date, calendar: Calendar = .current) -> Int {
        passes.filter { $0.approved && calendar.isDate($0.askedAt, inSameDayAs: now) }.count
    }
}
