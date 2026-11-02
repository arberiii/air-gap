import Foundation

/// What the floating card says when AirGap hides an app, so the user knows why it won't open.
public struct AppBlockNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blockList
        case limitReached(minutes: Int)
        case focus(intention: String, next: String?, secondsLeft: TimeInterval)
    }

    public var bundleID: String
    public var appName: String
    public var kind: Kind
    /// During focus: whether the app still has its one brief allowance this session.
    public var canAllowBriefly = true
    /// During focus: whether the app may be added to the focus list from the card. Off for reading themes.
    public var canAddToList = true
    /// The assistant that can be asked to open the app for a typed reason, or nil when asking is off.
    public var askAgentName: String?
    public var passesLeft = 0

    public init(bundleID: String, appName: String, kind: Kind) {
        self.bundleID = bundleID
        self.appName = appName
        self.kind = kind
    }

    /// The notice for a hidden app, or nil when the reason is about a website (the browser shows its own page).
    public init?(reason: BlockReason, bundleID: String, appName: String,
                 focus: (intention: String, next: String?, secondsLeft: TimeInterval)? = nil) {
        switch reason {
        case .rule(let rule) where rule.kind == .app:
            self.init(bundleID: bundleID, appName: appName, kind: .blockList)
        case .limitReached(let rule) where rule.kind == .app:
            self.init(bundleID: bundleID, appName: appName, kind: .limitReached(minutes: rule.dailyLimitMinutes ?? 0))
        case .focusApp:
            guard let focus else { return nil }
            self.init(bundleID: bundleID, appName: appName, kind: .focus(intention: focus.intention, next: focus.next, secondsLeft: focus.secondsLeft))
        default:
            return nil
        }
    }

    public var title: String {
        switch kind {
        case .blockList: return "\(appName) is blocked"
        case .limitReached: return "\(appName) is done for today"
        case .focus: return "\(appName) is paused"
        }
    }

    public var message: String {
        switch kind {
        case .blockList: return "It's on your block list, so AirGap hid it."
        case .limitReached(let minutes): return "You used your \(minutes) minutes. It opens again tomorrow."
        case .focus: return "You're focusing on"
        }
    }

    /// The line under the intention during focus: the next step and the minutes left.
    public var detail: String? {
        guard case .focus(_, let next, let secondsLeft) = kind else { return nil }
        let left = "\(Int((secondsLeft / 60).rounded(.up))) min left"
        guard let next, !next.isEmpty else { return left }
        return "Next: \(next) · \(left)"
    }

    public var isFocus: Bool { if case .focus = kind { return true } else { return false } }
}
