import XCTest
@testable import AirGapCore

final class PagePassTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pass(_ url: String, approved: Bool = true, minutesLeft: Double = 10, askedAt: Date? = nil) -> PagePass {
        PagePass(page: PagePass.page(from: URL(string: url)!)!, title: nil, reason: "Fixing the Swift build error", approved: approved,
                 reply: "", askedAt: askedAt ?? now, until: approved ? now.addingTimeInterval(minutesLeft * 60) : nil)
    }

    private func ctx(_ url: String) -> ActivityContext {
        ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: url))
    }

    func testPageIgnoresMirrorsTrackingAndFragments() {
        let thread = "https://www.reddit.com/r/swift/comments/abc/build_error/"
        let p = pass(thread)
        XCTAssertEqual(p.page, "reddit.com/r/swift/comments/abc/build_error")
        XCTAssertTrue(p.covers(URL(string: "https://old.reddit.com/r/swift/comments/abc/build_error?utm_source=share&utm_medium=web#c1")!))
        XCTAssertTrue(p.covers(URL(string: "https://reddit.com/r/swift/comments/abc/build_error/?share_id=x")!))
    }

    func testPassCoversOnlyThatPage() {
        let p = pass("https://www.reddit.com/r/swift/comments/abc/build_error/")
        XCTAssertFalse(p.covers(URL(string: "https://www.reddit.com/r/swift/")!))
        XCTAssertFalse(p.covers(URL(string: "https://www.reddit.com/")!))
        XCTAssertFalse(p.covers(URL(string: "https://www.reddit.com/r/swift/comments/xyz/other/")!))
    }

    func testMeaningfulQueryStillCounts() {
        let p = pass("https://www.youtube.com/watch?v=abc&si=tracking")
        XCTAssertTrue(p.covers(URL(string: "https://m.youtube.com/watch?v=abc")!))
        XCTAssertFalse(p.covers(URL(string: "https://www.youtube.com/watch?v=other")!))
    }

    func testPassLetsPageThroughBlockListAndFocus() {
        let rule = BlockRule.web("reddit.com", kind: .site)!
        let thread = "https://www.reddit.com/r/swift/comments/abc/build_error/"
        let passes = [pass(thread)]
        XCTAssertNil(BlockEvaluator.evaluate(ctx(thread), rules: [rule], secondsUsedToday: [:], focusAllowlist: ["github.com"], pagePasses: passes))
        XCTAssertNotNil(BlockEvaluator.evaluate(ctx("https://www.reddit.com/r/popular"), rules: [rule], secondsUsedToday: [:],
                                                focusAllowlist: nil, pagePasses: passes))
        XCTAssertEqual(BlockEvaluator.evaluate(ctx("https://www.reddit.com/r/popular"), rules: [], secondsUsedToday: [:],
                                               focusAllowlist: ["github.com"], pagePasses: passes), .focus)
    }

    func testPassDoesNotUnhideFocusApps() {
        let passes = [pass("https://www.reddit.com/r/swift/comments/abc/x/")]
        let context = ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", url: URL(string: "https://www.reddit.com/r/swift/comments/abc/x/"))
        XCTAssertEqual(BlockEvaluator.evaluate(context, rules: [], secondsUsedToday: [:], focusAllowlist: [], focusApps: ["com.apple.finder"],
                                               pagePasses: passes), .focusApp)
    }

    private func appPass(_ bundleID: String) -> PagePass {
        PagePass(page: PagePass.app(bundleID), title: "Slack", reason: "Reply to the release thread", approved: true, reply: "",
                 askedAt: now, until: now.addingTimeInterval(600))
    }

    func testAppPassLetsAppThroughFocusAndBlockList() {
        let slack = ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        let rule = BlockRule(kind: .app, value: "com.tinyspeck.slackmacgap")
        let passes = [appPass("com.tinyspeck.slackmacgap")]
        XCTAssertNil(BlockEvaluator.evaluate(slack, rules: [rule], secondsUsedToday: [:], focusAllowlist: [], focusApps: ["com.apple.finder"],
                                             pagePasses: passes))
        let discord = ActivityContext(bundleID: "com.hnc.Discord", appName: "Discord")
        XCTAssertEqual(BlockEvaluator.evaluate(discord, rules: [], secondsUsedToday: [:], focusAllowlist: [], focusApps: ["com.apple.finder"],
                                               pagePasses: passes), .focusApp)
    }

    func testAppPassForBrowserDoesNotOpenItsPages() {
        let chrome = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://www.reddit.com/"))
        let rule = BlockRule.web("reddit.com", kind: .site)!
        XCTAssertNotNil(BlockEvaluator.evaluate(chrome, rules: [rule], secondsUsedToday: [:], focusAllowlist: nil,
                                                pagePasses: [appPass("com.google.Chrome")]))
        XCTAssertFalse(appPass("com.google.Chrome").covers(URL(string: "https://www.reddit.com/")!))
    }

    func testAppPassPromptNamesTheApp() {
        let prompt = Coach.appPassPrompt(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", reason: "Reply to the release thread",
                                         blockedBecause: "Only your focus apps are allowed.", focus: "Ship the release", earlier: [appPass("x")])
        XCTAssertTrue(prompt.contains("App: Slack (com.tinyspeck.slackmacgap)"))
        XCTAssertTrue(prompt.contains("Ship the release"))
        XCTAssertTrue(prompt.contains("Slack app:x (approved)"))
    }

    func testActiveAndDailyCount() {
        XCTAssertTrue(pass("https://reddit.com/a").isActive(at: now))
        XCTAssertFalse(pass("https://reddit.com/a", minutesLeft: -1).isActive(at: now))
        XCTAssertFalse(pass("https://reddit.com/a", approved: false).isActive(at: now))
        let passes = [pass("https://reddit.com/a"), pass("https://reddit.com/b", approved: false),
                      pass("https://reddit.com/c", askedAt: now.addingTimeInterval(-2 * 86_400))]
        XCTAssertEqual(PagePass.approvedToday(passes, now: now), 1)
    }

    func testPagePassPromptCarriesReasonFocusAndEarlierAsks() {
        let prompt = Coach.pagePassPrompt(url: URL(string: "https://reddit.com/r/swift/comments/abc")!, title: "Build error help",
                                          reason: "Has the fix for my linker error", blockedBecause: "This is on your block list.",
                                          focus: "Ship the release build", earlier: [pass("https://reddit.com/r/other", approved: false)])
        XCTAssertTrue(prompt.contains("Has the fix for my linker error"))
        XCTAssertTrue(prompt.contains("Build error help"))
        XCTAssertTrue(prompt.contains("Ship the release build"))
        XCTAssertTrue(prompt.contains("reddit.com/r/other (declined)"))
        XCTAssertFalse(Coach.pagePassPrompt(url: URL(string: "https://reddit.com/x")!, title: nil, reason: "r", blockedBecause: "b",
                                            focus: nil, earlier: []).contains("focus session"))
    }

    func testDecodesPageVerdict() throws {
        let verdict = try Coach.decode(CoachPageVerdict.self, fromText: #"{"approve":true,"reply":"That thread has your fix."}"#)
        XCTAssertEqual(verdict, CoachPageVerdict(approve: true, reply: "That thread has your fix."))
    }
}
