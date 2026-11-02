import CryptoKit
import Foundation

/// What a commitment lock covers: the current focus session, one theme, or the block list.
public enum LockScope: Codable, Hashable, Sendable {
    case session
    case theme(UUID)
    case blockList
}

/// Someone else's code that opens a lock. Only a salted SHA-256 is kept, never the code.
public struct PartnerCode: Codable, Equatable, Sendable {
    public var salt: String
    public var hash: String

    public static func make(_ code: String) -> PartnerCode {
        var generator = SystemRandomNumberGenerator()
        let salt = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        return PartnerCode(salt: salt, hash: digest(salt: salt, code: code))
    }

    public func matches(_ code: String) -> Bool { !code.isEmpty && Self.digest(salt: salt, code: code) == hash }

    private static func digest(salt: String, code: String) -> String {
        SHA256.hash(data: Data((salt + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The way out chosen when the lock was set.
public enum LockOverride: Codable, Equatable, Sendable {
    /// A loosening change takes effect 24 hours later, or when the lock ends, whichever comes first.
    case delay
    /// Someone else types the code; the right code applies the change at once.
    case partner(PartnerCode)
}

/// A loosening change waiting for its delay to pass.
public struct PendingChange: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case unlock
        case removeRule(UUID)
        case addSite(String)
        case addApp(FocusApp)
    }

    public var id: UUID
    public var kind: Kind
    public var requestedAt: Date
    public var effectiveAt: Date
}

/// A promise the user made to a future, tired self: for a period, the rules stay as they are.
public struct CommitmentLock: Codable, Equatable, Identifiable, Sendable {
    public static let delay: TimeInterval = 24 * 3600
    public static let lengthOptionsDays = [1, 3, 7, 30]

    public var id: UUID
    public var scope: LockScope
    public var startedAt: Date
    public var endsAt: Date
    public var override: LockOverride
    /// Whether the quick check still works under this lock.
    public var allowsQuickCheck: Bool
    public var pending: [PendingChange]

    public init(id: UUID = UUID(), scope: LockScope, startedAt: Date, endsAt: Date, override: LockOverride,
                allowsQuickCheck: Bool = false, pending: [PendingChange] = []) {
        self.id = id
        self.scope = scope
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.override = override
        self.allowsQuickCheck = allowsQuickCheck
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case id, scope, startedAt, endsAt, override, allowsQuickCheck, pending }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scope = try c.decode(LockScope.self, forKey: .scope)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        override = try c.decode(LockOverride.self, forKey: .override)
        allowsQuickCheck = try c.decodeIfPresent(Bool.self, forKey: .allowsQuickCheck) ?? false
        pending = try c.decodeIfPresent([PendingChange].self, forKey: .pending) ?? []
    }

    public func isActive(at now: Date) -> Bool { startedAt <= now && now < endsAt }

    public var isDelay: Bool { if case .delay = override { return true } else { return false } }

    /// Session locks queue nothing: 24 hours is always later than the session's end.
    public var canQueue: Bool { isDelay && scope != .session }

    public func effectiveDate(requestedAt: Date) -> Date { min(requestedAt.addingTimeInterval(Self.delay), endsAt) }

    public func pending(_ kind: PendingChange.Kind) -> PendingChange? { pending.first { $0.kind == kind } }

    /// Queues a loosening change. Nil when this lock can't queue or the same change is already waiting.
    @discardableResult
    public mutating func queue(_ kind: PendingChange.Kind, at now: Date) -> PendingChange? {
        guard canQueue, pending(kind) == nil else { return nil }
        let change = PendingChange(id: UUID(), kind: kind, requestedAt: now, effectiveAt: effectiveDate(requestedAt: now))
        pending.append(change)
        return change
    }

    public mutating func cancel(_ id: UUID) { pending.removeAll { $0.id == id } }

    /// Removes and returns the changes whose delay has passed, in the order they were requested.
    public mutating func takeDue(at now: Date) -> [PendingChange.Kind] {
        let due = pending.filter { $0.effectiveAt <= now }
        pending.removeAll { $0.effectiveAt <= now }
        return due.map(\.kind)
    }
}

/// What the active locks mean for the running session.
public struct RunRestrictions: Equatable, Sendable {
    /// No pausing, no ending early.
    public var isHard: Bool
    public var allowsQuickCheck: Bool

    public init(isHard: Bool, allowsQuickCheck: Bool) {
        self.isHard = isHard
        self.allowsQuickCheck = allowsQuickCheck
    }

    public static let none = RunRestrictions(isHard: false, allowsQuickCheck: true)
}

/// Which lock, if any, stands between the user and an edit.
public enum LockPolicy {
    public static func active(_ locks: [CommitmentLock], at now: Date) -> [CommitmentLock] { locks.filter { $0.isActive(at: now) } }

    public static func lock(_ locks: [CommitmentLock], scope: LockScope, at now: Date) -> CommitmentLock? {
        active(locks, at: now).first { $0.scope == scope }
    }

    /// The lock on a focus list: the theme's own lock, or the session lock while the session uses that list.
    public static func focusListLock(_ locks: [CommitmentLock], theme: UUID?, sessionUsesList: Bool, at now: Date) -> CommitmentLock? {
        if let theme, let themeLock = lock(locks, scope: .theme(theme), at: now) { return themeLock }
        return sessionUsesList ? lock(locks, scope: .session, at: now) : nil
    }

    /// Most restrictive wins: hard if any covering lock is, quick check only if every covering lock allows it.
    public static func run(_ locks: [CommitmentLock], sessionTheme: UUID?, at now: Date) -> RunRestrictions {
        let covering = active(locks, at: now).filter { $0.scope == .session || (sessionTheme != nil && $0.themeID == sessionTheme) }
        guard !covering.isEmpty else { return .none }
        return RunRestrictions(isHard: true, allowsQuickCheck: covering.allSatisfy(\.allowsQuickCheck))
    }
}

private extension CommitmentLock {
    var themeID: UUID? { if case .theme(let id) = scope { return id } else { return nil } }
}

/// The LaunchAgent that reopens AirGap whenever it is not running, for as long as a lock holds.
public enum WatchdogPlist {
    public static let label = "com.arberiii.airgap.watchdog"

    /// The loop stops itself (exit 0, which `SuccessfulExit: false` does not restart) once `until` has passed,
    /// so a watchdog outlives neither the last lock nor an app that was moved away.
    public static func contents(appPath: String, bundleID: String, until: Date) -> String {
        let end = Int(until.timeIntervalSince1970)
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "while [ \"$(date +%s)\" -lt \(end) ]; do pgrep -xq AirGap || open -g \(quoted) || open -g -b \(bundleID); sleep 5; done; exit 0"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>/bin/sh</string><string>-c</string><string>\(HTML.escape(script))</string></array>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>RunAtLoad</key><true/>
        </dict></plist>

        """
    }
}
