import Foundation

public enum BlockReason: Equatable, Sendable {
    case rule(BlockRule)
    case limitReached(BlockRule)
    case focus
    /// An app that is not on the focus list was brought to the front during a focus session.
    case focusApp

    public var message: String {
        switch self {
        case .rule: return "This is on your block list."
        case .limitReached(let rule): return "You used your \(rule.dailyLimitMinutes ?? 0) minutes for today."
        case .focus: return "Only your focus list is allowed during a focus session."
        case .focusApp: return "Only your focus apps are allowed during a focus session."
        }
    }

    /// The block list rule behind a `.rule` or `.limitReached` block.
    public var rule: BlockRule? {
        switch self {
        case .rule(let rule), .limitReached(let rule): return rule
        case .focus, .focusApp: return nil
        }
    }

    /// Whether this block hides an app rather than redirecting a page.
    public var hidesApp: Bool { self == .focusApp || rule?.kind == .app }
}

public enum BlockEvaluator {
    /// Decides whether the current activity must be blocked.
    /// - Parameters:
    ///   - secondsUsedToday: seconds already spent today per rule id (used for daily limits).
    ///   - focusAllowlist: hosts allowed while focusing, or `nil` when no focus session is running.
    ///   - focusApps: bundle ids allowed while focusing (including always-allowed ones like browsers and Finder),
    ///     or `nil` to leave apps alone.
    ///   - pagePasses: active passes; a page or app one covers is let through both the focus list and the block list.
    ///     An app pass never lets the app's web pages through, so a pass for a browser is only a pass for the browser.
    public static func evaluate(
        _ context: ActivityContext,
        rules: [BlockRule],
        secondsUsedToday: [UUID: TimeInterval],
        focusAllowlist: [String]?,
        focusApps: Set<String>? = nil,
        pagePasses: [PagePass] = []
    ) -> BlockReason? {
        let appPassed = pagePasses.contains { $0.covers(app: context.bundleID) }
        if let apps = focusApps, !apps.contains(context.bundleID), !appPassed {
            return .focusApp
        }
        if let url = context.url, pagePasses.contains(where: { $0.covers(url) }) { return nil }
        if let allowlist = focusAllowlist, let host = context.webHost,
           !allowlist.contains(where: { URLNormalizer.host(host, isWithin: $0) }) {
            return .focus
        }

        for rule in rules where rule.matches(context) && !(appPassed && rule.kind == .app) {
            guard let limit = rule.dailyLimitMinutes else { return .rule(rule) }
            if secondsUsedToday[rule.id, default: 0] >= TimeInterval(limit * 60) {
                return .limitReached(rule)
            }
        }
        return nil
    }
}
