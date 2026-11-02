import XCTest
@testable import AirGapCore

final class UsageExportTests: XCTestCase {
    func testRowsPerDayOldestFirstLargestFirst() {
        var log = UsageLog()
        log.days = ["2026-10-21": ["app:com.tinyspeck.slackmacgap": 90],
                    "2026-10-20": ["web:youtube.com": 600, "app:com.tinyspeck.slackmacgap": 1200]]
        log.visitDays = ["2026-10-20": ["web:youtube.com": 3], "2026-10-22": ["web:news.ycombinator.com": 1]]
        log.appNames = ["com.tinyspeck.slackmacgap": "Slack"]

        XCTAssertEqual(UsageExport.csv(log, categorization: Categorization()), """
        date,type,name,identifier,category,minutes,opens
        2026-10-20,app,Slack,com.tinyspeck.slackmacgap,Communication,20.0,0
        2026-10-20,website,youtube.com,youtube.com,Video & Entertainment,10.0,3
        2026-10-21,app,Slack,com.tinyspeck.slackmacgap,Communication,1.5,0
        2026-10-22,website,news.ycombinator.com,news.ycombinator.com,Social,0.0,1

        """)
    }

    func testUsesUserCategoryNames() {
        var log = UsageLog()
        log.days = ["2026-10-20": ["web:example.com": 60]]
        var categories = Categorization()
        let work = categories.addCategory(named: "Work, mostly")!
        categories.setUserCategory(work.id, for: ["web:example.com"])
        XCTAssertTrue(UsageExport.csv(log, categorization: categories).contains("example.com,\"Work, mostly\",1.0,0"))
    }

    func testEmptyLogIsHeaderOnly() {
        XCTAssertEqual(UsageExport.csv(UsageLog(), categorization: Categorization()), UsageExport.header + "\n")
    }

    func testFieldQuoting() {
        XCTAssertEqual(UsageExport.field("plain"), "plain")
        XCTAssertEqual(UsageExport.field("a,b"), "\"a,b\"")
        XCTAssertEqual(UsageExport.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}
