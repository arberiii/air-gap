import XCTest
@testable import AirGapCore

final class HourlyUsageTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let youtube = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://youtube.com"))
    private let slack = ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func record(_ log: inout UsageLog, _ seconds: TimeInterval, _ context: ActivityContext, at date: Date) {
        log.record(seconds, context: context, matchedRules: [], on: date, calendar: calendar)
    }

    func testRecordFillsHourBucket() {
        var log = UsageLog()
        record(&log, 2, youtube, at: date(20, 14, 5))
        record(&log, 3, youtube, at: date(20, 14, 50))
        let hours = log.hourly(on: date(20, 9), calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[14]["web:youtube.com"], 5)
        for (hour, bucket) in hours.enumerated() where hour != 14 { XCTAssertTrue(bucket.isEmpty, "hour \(hour)") }
    }

    func testMidnightSplitsAcrossDays() {
        var log = UsageLog()
        record(&log, 2, youtube, at: date(19, 23, 59, 59))
        record(&log, 2, youtube, at: date(20, 0, 0, 1))
        XCTAssertEqual(log.hourly(on: date(19, 12), calendar: calendar)[23]["web:youtube.com"], 2)
        XCTAssertEqual(log.hourly(on: date(20, 12), calendar: calendar)[0]["web:youtube.com"], 2)
        XCTAssertNil(log.hourly(on: date(19, 12), calendar: calendar)[0]["web:youtube.com"])
    }

    func testUntrackedActivityNotInHours() {
        var log = UsageLog()
        let rule = BlockRule.web("youtube.com", kind: .site)!
        log.record(2, context: youtube, matchedRules: [rule], on: date(20, 10), logActivity: false, calendar: calendar)
        XCTAssertTrue(log.hours.isEmpty)
        XCTAssertFalse(log.ruleDays.isEmpty)
    }

    func testRemoveClearsHours() {
        var log = UsageLog()
        record(&log, 2, youtube, at: date(20, 10))
        record(&log, 4, slack, at: date(20, 11))
        log.remove(key: "web:youtube.com")
        let hours = log.hourly(on: date(20, 0), calendar: calendar)
        XCTAssertTrue(hours.allSatisfy { $0["web:youtube.com"] == nil })
        XCTAssertEqual(hours[11]["app:com.tinyspeck.slackmacgap"], 4)
        log.remove(key: "app:com.tinyspeck.slackmacgap")
        XCTAssertTrue(log.hours.isEmpty)
    }

    func testPruneKeepsSixtyDays() {
        var log = UsageLog()
        let now = date(20, 12)
        for offset in [0, 59, 60] {
            record(&log, 2, youtube, at: calendar.date(byAdding: .day, value: -offset, to: now)!)
        }
        log.prune(now: now, calendar: calendar)
        let key = { (offset: Int) in UsageLog.dayKey(self.calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: self.calendar) }
        XCTAssertNotNil(log.hours[key(0)])
        XCTAssertNotNil(log.hours[key(59)])
        XCTAssertNil(log.hours[key(60)])
        XCTAssertEqual(log.days.count, 3)
        XCTAssertEqual(Array(log.ruleDays.keys), [], "no rules matched, so no rule time")
    }

    func testUsageWithoutHoursDecodes() throws {
        let log = try JSONDecoder().decode(UsageLog.self, from: Data(#"{"days":{"2026-10-01":{"app:x":10}}}"#.utf8))
        XCTAssertTrue(log.hours.isEmpty)
        XCTAssertEqual(log.days["2026-10-01"]?["app:x"], 10)
    }
}
