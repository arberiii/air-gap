import Foundation

public enum URLNormalizer {
    /// Lowercased host without a leading `www.`, or `nil` when the input has no usable host.
    public static func host(from input: String) -> String? {
        guard let components = components(from: input), var host = components.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, host.contains(".") || host == "localhost" else { return nil }
        return host
    }

    /// `host/path` plus `?query` when present. Trailing slashes and fragments are dropped.
    public static func page(from input: String) -> String? {
        guard let components = components(from: input), let host = host(from: input) else { return nil }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        var result = host + path
        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?" + query
        }
        return result
    }

    /// `m.youtube.com` and `youtube.com` are both within `youtube.com`; `notyoutube.com` is not.
    public static func host(_ host: String, isWithin ruleHost: String) -> Bool {
        host == ruleHost || host.hasSuffix("." + ruleHost)
    }

    /// Same host (ignoring `www.`) and same path. If the rule has a query, every one of its
    /// parameters must be present in the URL, so `youtube.com/watch?v=abc` still matches
    /// `youtube.com/watch?v=abc&t=42`. A rule without a query matches any query.
    public static func url(_ url: URL, matchesPage rule: String) -> Bool {
        guard let candidate = page(from: url.absoluteString),
              let ruleComponents = components(from: rule),
              let candidateComponents = components(from: candidate) else { return false }

        let ruleHostPath = rule.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rule
        let candidateHostPath = candidate.split(separator: "?", maxSplits: 1).first.map(String.init) ?? candidate
        guard ruleHostPath == candidateHostPath else { return false }

        let required = Set((ruleComponents.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" })
        let present = Set((candidateComponents.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" })
        return required.isSubset(of: present)
    }

    private static func components(from input: String) -> URLComponents? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URLComponents(string: withScheme)
    }
}
