import XCTest
@testable import AirGapCore

final class UsageChartTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let browsers: Set<String> = ["com.google.Chrome"]

    private func web(_ host: String) -> ActivityContext {
        ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://\(host)"))
    }
    private let claudeApp = ActivityContext(bundleID: "com.anthropic.claudefordesktop", appName: "Claude")
    private let unknownApp = ActivityContext(bundleID: "com.example.thing", appName: "Thing")

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func record(_ log: inout UsageLog, _ seconds: TimeInterval, _ context: ActivityContext, at date: Date) {
        log.record(seconds, context: context, matchedRules: [], on: date, calendar: calendar)
    }

    func testHourlyStacksByCategory() {
        var log = UsageLog()
        record(&log, 60, web("youtube.com"), at: date(20, 14, 5))
        record(&log, 30, web("reddit.com"), at: date(20, 14, 10))
        record(&log, 10, unknownApp, at: date(20, 14, 20))
        let slices = UsageChart.hourly(log, on: date(20, 9), grouping: UsageGrouping(), categories: Categorization(),
                                       excludedApps: browsers, calendar: calendar)
        let two = date(20, 14)
        XCTAssertEqual(slices, [
            CategorySlice(bucket: two, categoryID: "social", seconds: 30),
            CategorySlice(bucket: two, categoryID: "video", seconds: 60),
            CategorySlice(bucket: two, categoryID: "other", seconds: 10),
        ])
    }

    func testGroupedRowUsesHeadCategory() {
        var log = UsageLog()
        record(&log, 20, claudeApp, at: date(20, 10))
        record(&log, 40, web("claude.ai"), at: date(20, 10))
        var grouping = UsageGrouping()
        grouping.group("web:claude.ai", with: "app:com.anthropic.claudefordesktop", appNames: log.appNames, excludedApps: browsers)
        var categories = Categorization()
        categories.setUserCategory("games", for: ["app:com.anthropic.claudefordesktop"])
        categories.beginLabeling(["web:claude.ai"])
        categories.applyAssistantLabels(["web:claude.ai": "social"], asked: ["web:claude.ai"])
        let slices = UsageChart.hourly(log, on: date(20, 0), grouping: grouping, categories: categories,
                                       excludedApps: browsers, calendar: calendar)
        XCTAssertEqual(slices, [CategorySlice(bucket: date(20, 10), categoryID: "games", seconds: 60)])
    }

    func testDailyOldestFirst() {
        var log = UsageLog()
        for day in [18, 19, 20] { record(&log, TimeInterval(day), web("youtube.com"), at: date(day, 12)) }
        let slices = UsageChart.daily(log, lastDays: 3, endingOn: date(20, 23), grouping: UsageGrouping(), categories: Categorization(),
                                      excludedApps: browsers, calendar: calendar)
        XCTAssertEqual(slices.map(\.bucket), [date(18, 0), date(19, 0), date(20, 0)])
        XCTAssertEqual(slices.map(\.seconds), [18, 19, 20])
        XCTAssertTrue(slices.allSatisfy { $0.categoryID == "video" })
    }

    func testLegendSumsToTotal() {
        var log = UsageLog()
        record(&log, 100, web("youtube.com"), at: date(20, 9))
        record(&log, 50, web("netflix.com"), at: date(20, 9))
        record(&log, 300, claudeApp, at: date(20, 10))
        record(&log, 25, web("claude.ai"), at: date(20, 10))
        record(&log, 10, unknownApp, at: date(20, 11))
        let rows = UsageGrouping().apply(log.totals(lastDays: 1, endingOn: date(20, 12), calendar: calendar),
                                         appNames: log.appNames, excludedApps: browsers)
        let legend = UsageChart.legend(rows, categories: Categorization())
        XCTAssertEqual(legend.map(\.category.id), ["productivity", "video", "other"])
        XCTAssertEqual(legend.map(\.seconds), [325, 150, 10])
        XCTAssertEqual(legend.reduce(0) { $0 + $1.seconds }, rows.reduce(0) { $0 + $1.seconds })
    }
}
