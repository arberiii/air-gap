import XCTest
@testable import AirGapCore

final class LockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    private func lock(_ scope: LockScope, length: TimeInterval, override: LockOverride = .delay, quick: Bool = false) -> CommitmentLock {
        CommitmentLock(scope: scope, startedAt: t0, endsAt: t0.addingTimeInterval(length), override: override, allowsQuickCheck: quick)
    }

    func testActiveWindowAndExpiry() {
        let l = lock(.blockList, length: days(1))
        XCTAssertTrue(l.isActive(at: t0))
        XCTAssertTrue(l.isActive(at: t0.addingTimeInterval(days(1) - 1)))
        XCTAssertFalse(l.isActive(at: t0.addingTimeInterval(days(1))))
        XCTAssertFalse(l.isActive(at: t0.addingTimeInterval(-1)))
        let expired = lock(.theme(UUID()), length: 60)
        XCTAssertEqual(LockPolicy.active([l, expired], at: t0.addingTimeInterval(3600)).map(\.id), [l.id])
    }

    func testEffectiveDateIsDelayOrLockEndWhicheverFirst() {
        let long = lock(.blockList, length: days(30))
        XCTAssertEqual(long.effectiveDate(requestedAt: t0.addingTimeInterval(3600)), t0.addingTimeInterval(3600 + CommitmentLock.delay))
        let short = lock(.blockList, length: 7200)
        XCTAssertEqual(short.effectiveDate(requestedAt: t0.addingTimeInterval(3600)), short.endsAt)
    }

    func testSessionAndPartnerLocksQueueNothing() {
        var session = lock(.session, length: 3600)
        XCTAssertFalse(session.canQueue)
        XCTAssertNil(session.queue(.unlock, at: t0))
        var partner = lock(.blockList, length: days(1), override: .partner(PartnerCode.make("4711")))
        XCTAssertFalse(partner.canQueue)
        XCTAssertNil(partner.queue(.unlock, at: t0))
        XCTAssertTrue(partner.pending.isEmpty)
    }

    func testQueueDedupesCancelAndTakeDue() {
        var l = lock(.blockList, length: days(30))
        let rule = UUID()
        let first = l.queue(.removeRule(rule), at: t0)
        XCTAssertNotNil(first)
        XCTAssertNil(l.queue(.removeRule(rule), at: t0.addingTimeInterval(10)))
        let later = l.queue(.unlock, at: t0.addingTimeInterval(3600))!
        XCTAssertEqual(l.pending.count, 2)
        XCTAssertEqual(l.pending(.unlock)?.id, later.id)

        XCTAssertEqual(l.takeDue(at: t0.addingTimeInterval(CommitmentLock.delay - 1)), [])
        XCTAssertEqual(l.takeDue(at: t0.addingTimeInterval(CommitmentLock.delay)), [.removeRule(rule)])
        XCTAssertEqual(l.pending.map(\.id), [later.id])

        l.cancel(later.id)
        XCTAssertTrue(l.pending.isEmpty)
    }

    func testPartnerCodeHashesAndMatches() {
        let code = PartnerCode.make("4711")
        XCTAssertTrue(code.matches("4711"))
        XCTAssertFalse(code.matches("4712"))
        XCTAssertFalse(code.matches(""))
        XCTAssertNotEqual(code.hash, "4711")
        XCTAssertEqual(code.hash.count, 64)
        XCTAssertNotEqual(code.salt, PartnerCode.make("4711").salt)
    }

    func testBlockListLockFoundByScope() {
        let l = lock(.blockList, length: days(1))
        XCTAssertEqual(LockPolicy.lock([l], scope: .blockList, at: t0)?.id, l.id)
        XCTAssertNil(LockPolicy.lock([l], scope: .session, at: t0))
        XCTAssertNil(LockPolicy.lock([l], scope: .blockList, at: t0.addingTimeInterval(days(2))))
    }

    func testFocusListLockPrefersThemeLockThenSessionLock() {
        let a = UUID(), b = UUID()
        let theme = lock(.theme(a), length: days(7))
        let session = lock(.session, length: 3600)
        XCTAssertEqual(LockPolicy.focusListLock([session, theme], theme: a, sessionUsesList: true, at: t0)?.id, theme.id)
        XCTAssertNil(LockPolicy.focusListLock([theme], theme: b, sessionUsesList: false, at: t0))
        XCTAssertNil(LockPolicy.focusListLock([theme], theme: nil, sessionUsesList: false, at: t0))
        XCTAssertEqual(LockPolicy.focusListLock([session], theme: nil, sessionUsesList: true, at: t0)?.id, session.id)
        XCTAssertNil(LockPolicy.focusListLock([session], theme: nil, sessionUsesList: false, at: t0))
    }

    func testRunRestrictionsCombineMostRestrictive() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(LockPolicy.run([], sessionTheme: a, at: t0), .none)
        let theme = lock(.theme(a), length: days(7), quick: true)
        XCTAssertEqual(LockPolicy.run([theme], sessionTheme: a, at: t0), RunRestrictions(isHard: true, allowsQuickCheck: true))
        XCTAssertEqual(LockPolicy.run([theme], sessionTheme: b, at: t0), .none)
        XCTAssertEqual(LockPolicy.run([theme], sessionTheme: nil, at: t0), .none)
        let session = lock(.session, length: 3600, quick: false)
        XCTAssertEqual(LockPolicy.run([theme, session], sessionTheme: a, at: t0), RunRestrictions(isHard: true, allowsQuickCheck: false))
        XCTAssertEqual(LockPolicy.run([lock(.blockList, length: days(1))], sessionTheme: nil, at: t0), .none)
    }

    func testPendingDecodesAsEmptyWhenMissing() throws {
        let json = """
        {"id":"\(UUID().uuidString)","scope":{"blockList":{}},"startedAt":0,"endsAt":86400,"override":{"delay":{}},"allowsQuickCheck":false}
        """
        let l = try JSONDecoder().decode(CommitmentLock.self, from: Data(json.utf8))
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertEqual(l.scope, .blockList)
        let again = try JSONDecoder().decode(CommitmentLock.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(again, l)
    }

    func testChangeDueAtLockEndIsTakenAtLockEnd() {
        var l = lock(.blockList, length: 7200)
        let rule = UUID()
        l.queue(.removeRule(rule), at: t0.addingTimeInterval(3600))
        XCTAssertEqual(l.pending.first?.effectiveAt, l.endsAt)
        XCTAssertFalse(l.isActive(at: l.endsAt))
        XCTAssertEqual(l.takeDue(at: l.endsAt), [.removeRule(rule)])
        XCTAssertEqual(l.takeDue(at: l.endsAt.addingTimeInterval(days(3))), [])
    }

    func testWatchdogPlistKeepsAliveOpensAppAndStopsAtLockEnd() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let plist = WatchdogPlist.contents(appPath: "/Applications/Air Gap's.app", bundleID: "com.arberiii.airgap", until: end)
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(plist.contains("<key>SuccessfulExit</key><false/>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key><true/>"))
        XCTAssertTrue(plist.contains("<string>com.arberiii.airgap.watchdog</string>"))
        XCTAssertTrue(plist.contains(HTML.escape("open -g '/Applications/Air Gap'\\''s.app'")))
        XCTAssertTrue(plist.contains("open -g -b com.arberiii.airgap"))
        XCTAssertTrue(plist.contains("sleep 5"))
        XCTAssertTrue(plist.contains("1800000000"))
        XCTAssertTrue(plist.contains("exit 0"))
    }
}
