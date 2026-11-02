import Foundation

public enum BlockKind: String, Codable, CaseIterable, Sendable {
    /// A whole website, including every subdomain (`youtube.com` also blocks `m.youtube.com`).
    case site
    /// One exact page (`youtube.com/shorts`) while the rest of the site stays reachable.
    case page
    /// A macOS application, identified by its bundle identifier.
    case app

    public var label: String {
        switch self {
        case .site: return "Whole site"
        case .page: return "Exact page"
        case .app: return "App"
        }
    }
}

public struct BlockRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: BlockKind
    /// Normalized host for `.site`, normalized `host/path?query` for `.page`, bundle id for `.app`.
    public var value: String
    public var displayName: String
    /// `nil` blocks all the time; otherwise blocks once this many minutes were used today.
    public var dailyLimitMinutes: Int?

    public init(id: UUID = UUID(), kind: BlockKind, value: String, displayName: String? = nil, dailyLimitMinutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.displayName = displayName ?? value
        self.dailyLimitMinutes = dailyLimitMinutes
    }

    /// Builds a site or page rule from whatever the user typed ("https://www.YouTube.com/shorts/", "reddit.com", ...).
    public static func web(_ input: String, kind: BlockKind, dailyLimitMinutes: Int? = nil) -> BlockRule? {
        switch kind {
        case .site:
            guard let host = URLNormalizer.host(from: input) else { return nil }
            return BlockRule(kind: .site, value: host, dailyLimitMinutes: dailyLimitMinutes)
        case .page:
            guard let page = URLNormalizer.page(from: input) else { return nil }
            return BlockRule(kind: .page, value: page, dailyLimitMinutes: dailyLimitMinutes)
        case .app:
            return nil
        }
    }

    public func matches(_ context: ActivityContext) -> Bool {
        switch kind {
        case .app:
            return context.bundleID == value
        case .site:
            guard let host = context.webHost else { return false }
            return URLNormalizer.host(host, isWithin: value)
        case .page:
            guard let url = context.url else { return false }
            return URLNormalizer.url(url, matchesPage: value)
        }
    }
}

/// What the user is looking at right now.
public struct ActivityContext: Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    /// Only set for http(s) pages in a supported browser.
    public var url: URL?

    public init(bundleID: String, appName: String, url: URL? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            self.url = url
        } else {
            self.url = nil
        }
    }

    public var webHost: String? {
        url.flatMap { URLNormalizer.host(from: $0.absoluteString) }
    }
}
