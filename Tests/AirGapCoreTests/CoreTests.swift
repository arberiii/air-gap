import XCTest
@testable import AirGapCore

final class CoreTests: XCTestCase {
    private func ctx(_ url: String, bundle: String = "com.google.Chrome") -> ActivityContext {
        ActivityContext(bundleID: bundle, appName: "Browser", url: URL(string: url))
    }

    func testHostNormalization() {
        XCTAssertEqual(URLNormalizer.host(from: "https://www.YouTube.com/shorts/"), "youtube.com")
        XCTAssertEqual(URLNormalizer.host(from: "reddit.com"), "reddit.com")
        XCTAssertNil(URLNormalizer.host(from: "   "))
        XCTAssertNil(URLNormalizer.host(from: "nodots"))
    }

    func testSiteRuleBlocksSubdomainsButNotLookalikes() {
        let rule = BlockRule.web("www.youtube.com", kind: .site)!
        XCTAssertTrue(rule.matches(ctx("https://m.youtube.com/watch?v=1")))
        XCTAssertTrue(rule.matches(ctx("https://youtube.com")))
        XCTAssertFalse(rule.matches(ctx("https://notyoutube.com")))
    }

    func testExactPageRuleOnlyBlocksThatPage() {
        let rule = BlockRule.web("https://youtube.com/shorts", kind: .page)!
        XCTAssertTrue(rule.matches(ctx("https://www.youtube.com/shorts/")))
        XCTAssertFalse(rule.matches(ctx("https://www.youtube.com/watch?v=1")))
        XCTAssertFalse(rule.matches(ctx("https://www.youtube.com/shorts/abc")))
    }

    func testPageRuleWithQueryMatchesSupersetOfParams() {
        let rule = BlockRule.web("youtube.com/watch?v=abc", kind: .page)!
        XCTAssertTrue(rule.matches(ctx("https://youtube.com/watch?v=abc&t=42")))
        XCTAssertFalse(rule.matches(ctx("https://youtube.com/watch?v=other")))
    }

    func testAppRuleAndNonWebURLsIgnored() {
        let rule = BlockRule(kind: .app, value: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(rule.matches(ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")))
        XCTAssertNil(ActivityContext(bundleID: "x", appName: "x", url: URL(string: "file:///tmp/a")).url)
    }

    func testDailyLimitBlocksOnlyAfterLimit() {
        let rule = BlockRule.web("reddit.com", kind: .site, dailyLimitMinutes: 10)!
        let c = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://reddit.com"))
        XCTAssertNil(BlockEvaluator.evaluate(c, rules: [rule], secondsUsedToday: [rule.id: 599], focusAllowlist: nil))
        XCTAssertEqual(BlockEvaluator.evaluate(c, rules: [rule], secondsUsedToday: [rule.id: 600], focusAllowlist: nil), .limitReached(rule))
    }

    func testFocusAllowlistBlocksOtherSitesOnly() {
        let c = ctx("https://news.ycombinator.com")
        XCTAssertEqual(BlockEvaluator.evaluate(c, rules: [], secondsUsedToday: [:], focusAllowlist: ["github.com"]), .focus)
        XCTAssertNil(BlockEvaluator.evaluate(ctx("https://gist.github.com"), rules: [], secondsUsedToday: [:], focusAllowlist: ["github.com"]))
        XCTAssertNil(BlockEvaluator.evaluate(ActivityContext(bundleID: "com.apple.Xcode", appName: "Xcode"), rules: [], secondsUsedToday: [:], focusAllowlist: ["github.com"]))
    }

    func testUsageLogAggregates() {
        var log = UsageLog()
        let now = Date()
        log.record(60, context: ctx("https://github.com/x"), matchedRules: [], on: now)
        log.record(30, context: ctx("https://github.com/y"), matchedRules: [], on: now)
        let totals = log.totals(lastDays: 1, endingOn: now)
        XCTAssertEqual(totals.first?.seconds, 90)
        XCTAssertEqual(totals.first?.title, "github.com")
        XCTAssertEqual(log.dailyTotals(lastDays: 7, endingOn: now).count, 7)
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.countdown(28800), "8:00:00")
        XCTAssertEqual(Formatting.countdown(59), "0:59")
        XCTAssertEqual(Formatting.duration(7500), "2h 05m")
        XCTAssertEqual(Formatting.duration(45), "45s")
    }
}

final class VisitCountTests: XCTestCase {
    func testUsageWithoutVisitsDecodes() throws {
        let log = try JSONDecoder().decode(UsageLog.self, from: Data(#"{"days":{},"ruleDays":{},"appNames":{}}"#.utf8))
        XCTAssertTrue(log.visitDays.isEmpty)
    }

    func testVisitsAreAggregatedInTotals() {
        var log = UsageLog()
        let now = Date()
        let c = ActivityContext(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp")
        log.recordVisit(context: c, on: now)
        log.recordVisit(context: c, on: now)
        XCTAssertEqual(log.totals(lastDays: 1, endingOn: now).first?.visits, 2)
    }

    func testTotalsCanBeSortedByOpens() {
        var log = UsageLog()
        let now = Date()
        let long = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
        let often = ActivityContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        log.record(600, context: long, matchedRules: [], on: now)
        log.recordVisit(context: long, on: now)
        log.record(60, context: often, matchedRules: [], on: now)
        for _ in 0..<5 { log.recordVisit(context: often, on: now) }
        XCTAssertEqual(log.totals(lastDays: 1, endingOn: now).first?.title, "Xcode")
        XCTAssertEqual(log.totals(lastDays: 1, endingOn: now, sortedBy: .opens).first?.title, "Slack")
    }
}

final class FocusSessionTests: XCTestCase {
    func testSummarySplitsFocusListOtherWebAndApps() {
        var session = FocusSession(intention: "Write", plannedMinutes: 60, startedAt: Date(), allowlist: ["github.com"])
        session.record(600, key: "web:gist.github.com")
        session.record(120, key: "web:youtube.com")
        session.record(300, key: "app:com.apple.dt.Xcode")
        session.recordBlocked(key: "web:youtube.com")
        session.recordBlocked(key: "web:youtube.com")
        let s = session.summary(appNames: ["com.apple.dt.Xcode": "Xcode"])
        XCTAssertEqual(s.focusListSeconds, 600)
        XCTAssertEqual(s.otherWebSeconds, 120)
        XCTAssertEqual(s.appSeconds, 300)
        XCTAssertEqual(s.blockedAttempts, 2)
        XCTAssertEqual(s.top.map(\.name), ["gist.github.com", "Xcode", "youtube.com"])
    }

    func testNextStepIsFirstOpenStep() {
        var session = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date(),
                                   steps: [FocusStep(text: "a", done: true), FocusStep(text: "b"), FocusStep(text: "c")])
        XCTAssertEqual(session.nextStep?.text, "b")
        session.steps[1].done = true; session.steps[2].done = true
        XCTAssertNil(session.nextStep)
    }

    func testHTMLEscapeNeutralizesMarkup() {
        XCTAssertEqual(HTML.escape("<script>alert(\"x\")</script> & 'y'"),
                       "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;y&#39;")
    }

    func testSessionRoundTripsThroughJSON() throws {
        let session = FocusSession(intention: "Ship", plannedMinutes: 120, startedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(FocusSession.self, from: data), session)
    }
}

final class CoachTests: XCTestCase {
    func testDecodesStructuredOutput() throws {
        let json = #"{"type":"result","is_error":false,"result":"ignored","structured_output":{"steps":["a","b"],"firstMove":"open doc","sites":["docs.google.com"],"apps":["com.apple.dt.Xcode"],"encouragement":"go"}}"#
        let plan = try Coach.decode(CoachPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan, CoachPlan(steps: ["a", "b"], firstMove: "open doc", sites: ["docs.google.com"], apps: ["com.apple.dt.Xcode"], encouragement: "go"))
    }

    func testFallsBackToFencedResultText() throws {
        let json = #"{"is_error":false,"result":"```json\n{\"reflection\":\"nice\",\"nextIntention\":\"next\"}\n```"}"#
        XCTAssertEqual(try Coach.decode(CoachReflection.self, from: Data(json.utf8)), CoachReflection(reflection: "nice", nextIntention: "next"))
    }

    func testReportsCLIErrors() {
        let json = #"{"is_error":true,"result":"Not logged in"}"#
        XCTAssertThrowsError(try Coach.decode(CoachPlan.self, from: Data(json.utf8))) { XCTAssertEqual($0 as? CoachError, .failed("Not logged in")) }
        XCTAssertThrowsError(try Coach.decode(CoachPlan.self, from: Data("not json".utf8))) { XCTAssertEqual($0 as? CoachError, .unreadable) }
    }

    func testDecodesCodexAnswerText() throws {
        let answer = "```json\n{\"reflection\":\"nice\",\"nextIntention\":\"next\"}\n```\n"
        XCTAssertEqual(try Coach.decode(CoachReflection.self, fromText: answer), CoachReflection(reflection: "nice", nextIntention: "next"))
        XCTAssertThrowsError(try Coach.decode(CoachReflection.self, fromText: "sorry")) { XCTAssertEqual($0 as? CoachError, .unreadable) }
    }

    func testReadsCodexErrors() {
        let stderr = """
        hook: SessionStart
        ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The model is not supported."}}
        """
        XCTAssertEqual(Coach.codexError(stderr), "The model is not supported.")
        XCTAssertEqual(Coach.codexError("ERROR: Not logged in\n"), "Not logged in")
        XCTAssertEqual(Coach.codexError("starting\nsomething broke\n"), "something broke")
        XCTAssertEqual(Coach.codexError(""), "")
    }

    func testSuggestedSitesSkipDistractionsBlockedAndListedHosts() {
        var past = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date())
        past.recordBlocked(key: "web:x.com")
        let rules = [BlockRule.web("reddit.com", kind: .site)!]
        let sites = Coach.usableSites(["x.com", "https://www.reddit.com", "gist.github.com", "docs.google.com", "Docs.Google.com", "nonsense"],
                                      allowlist: ["github.com"], rules: rules, history: [past])
        XCTAssertEqual(sites, ["docs.google.com"])
    }

    func testProposalKeepsOnlyKnownUsefulAppsAndSites() {
        var past = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date())
        past.recordBlocked(key: "app:net.whatsapp.WhatsApp"); past.recordBlocked(key: "web:x.com")
        let known = [FocusApp(bundleID: "com.apple.dt.Xcode", name: "Xcode"), FocusApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                     FocusApp(bundleID: "com.spotify.client", name: "Spotify"), FocusApp(bundleID: "com.google.Chrome", name: "Chrome")]
        let plan = CoachPlan(steps: [], firstMove: "", sites: ["github.com", "x.com"],
                             apps: ["com.apple.dt.Xcode", "com.apple.dt.Xcode", "net.whatsapp.WhatsApp", "com.spotify.client", "com.google.Chrome", "made.up"],
                             encouragement: "")
        var proposal = Coach.proposal(from: plan, known: known, alwaysAllowed: ["com.google.Chrome"],
                                      rules: [BlockRule(kind: .app, value: "com.spotify.client", displayName: "Spotify")], history: [past])
        XCTAssertEqual(proposal.sites, ["github.com"], "sites already on the list stay in the proposal; distractions don't")
        XCTAssertEqual(proposal.apps.map(\.bundleID), ["com.apple.dt.Xcode"])
        proposal.skipped = ["web:github.com"]
        XCTAssertEqual(proposal.chosenSites, [])
        XCTAssertEqual(proposal.chosenApps.map(\.name), ["Xcode"])
    }

    func testMergeStepsKeepsChecklistAndSkipsRepeats() {
        XCTAssertEqual(Coach.mergeSteps(checklist: ["Clear Triage inbox", "Assign owners"],
                                        planned: ["clear triage inbox ", "Flag blockers", "", "Assign owners"]),
                       ["Clear Triage inbox", "Assign owners", "Flag blockers"])
    }

    func testThemedPromptsUseThemeHistoryAndNotes() {
        let theme = FocusTheme(name: "News", kind: .reading, minutes: 30, intention: "Catch up", checklist: [], sites: ["ft.com"], apps: [])
        var past = FocusSession(intention: "Catch up", plannedMinutes: 30, startedAt: Date())
        past.themeID = theme.id; past.themeKind = .reading; past.nextTime = "Skip opinion pieces"
        let plan = Coach.planPrompt(intention: "Catch up", minutes: 30, allowlist: theme.sites, history: [past], todayTop: [], theme: theme)
        XCTAssertTrue(plan.contains("News") && plan.contains("Skip opinion pieces") && plan.contains("what to look for or read"))
        past.endedAt = Date(); past.outcome = .partly
        let reflect = Coach.reflectionPrompt(session: past, appNames: [:], history: [past], theme: theme)
        XCTAssertTrue(reflect.contains("News") && reflect.contains("takeaway"))
    }

    func testSchemasAreValidJSON() {
        for schema in [Coach.planSchema, Coach.reflectionSchema] {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(schema.utf8)))
        }
    }

    func testPromptsCarryIntentionHistoryAndSessionData() {
        var past = FocusSession(intention: "Old goal", plannedMinutes: 60, startedAt: Date())
        past.outcome = .partly; past.note = "Slack pinged"; past.recordBlocked(key: "web:reddit.com")
        let recent = [UsageEntry(key: "app:com.apple.dt.Xcode", seconds: 3600, visits: 3, appName: "Xcode"),
                      UsageEntry(key: "web:figma.com", seconds: 600, visits: 2, appName: nil)]
        let plan = Coach.planPrompt(intention: "New goal", minutes: 120, allowlist: ["github.com"], history: [past], todayTop: [], recent: recent)
        XCTAssertTrue(plan.contains("New goal") && plan.contains("120-minute") && plan.contains("github.com"))
        XCTAssertTrue(plan.contains("com.apple.dt.Xcode = Xcode") && plan.contains("figma.com"))
        XCTAssertTrue(plan.contains("Old goal") && plan.contains("Partly") && plan.contains("Slack pinged") && plan.contains("reddit.com"))

        var now = FocusSession(intention: "New goal", plannedMinutes: 60, startedAt: Date(timeIntervalSinceNow: -1800), steps: [FocusStep(text: "step one", done: true)])
        now.endedAt = Date(); now.outcome = .done; now.recordBlocked(key: "web:x.com")
        let reflect = Coach.reflectionPrompt(session: now, appNames: [:], history: [past, now])
        XCTAssertTrue(reflect.contains("[done] step one") && reflect.contains("x.com ×1") && reflect.contains("Yes"))
        XCTAssertEqual(reflect.components(separatedBy: "\"New goal\"").count, 1, "the current session is not repeated as history")
    }

    func testUsageSummaryComparesWithThePeriodBefore() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode", url: nil)
        let reddit = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://reddit.com/"))
        var usage = UsageLog()
        usage.record(7200, context: xcode, matchedRules: [], on: now, logActivity: true)
        usage.record(600, context: reddit, matchedRules: [], on: now)
        usage.record(3600, context: reddit, matchedRules: [], on: yesterday)
        let prompt = Coach.usageSummaryPrompt(usage: usage, days: 1, rules: [BlockRule(kind: .site, value: "reddit.com", dailyLimitMinutes: 15)],
                                              allowlist: ["github.com"], focusApps: [], history: [], now: now, calendar: cal)
        XCTAssertTrue(prompt.contains("Total for today: 2h 10m") && prompt.contains("For yesterday: 1h 00m"))
        XCTAssertTrue(prompt.contains("- Xcode (app): 2h 00m, 0 opens; not used"))
        XCTAssertTrue(prompt.contains("- reddit.com: 10m, 0 opens; 1h 00m, 0 opens"))
        XCTAssertTrue(prompt.contains("reddit.com (15 min/day allowed)") && prompt.contains("github.com"))

        let output = #"{"is_error":false,"structured_output":{"headline":"h","trend":"better","productivity":"p","patterns":["a"],"suggestion":"s"}}"#
        XCTAssertEqual(try Coach.decode(CoachUsageSummary.self, from: Data(output.utf8)).trend, .better)
    }
}

final class QuickAllowTests: XCTestCase {
    func testNoticeDefaultsAllowBothEscapes() {
        let notice = AppBlockNotice(bundleID: "a", appName: "A", kind: .blockList)
        XCTAssertTrue(notice.canAllowBriefly)
        XCTAssertTrue(notice.canAddToList)
    }

    func testBriefAllowanceEndsAndIsOncePerSession() {
        let start = Date()
        var session = FocusSession(intention: "x", plannedMinutes: 60, startedAt: start)
        XCTAssertTrue(session.allowBriefly(key: "app:net.whatsapp.WhatsApp", until: start.addingTimeInterval(300)))
        XCTAssertTrue(session.allowBriefly(key: "web:x.com", until: start.addingTimeInterval(600)))
        XCTAssertEqual(session.brieflyAllowed(at: start).apps, ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(session.brieflyAllowed(at: start).hosts, ["x.com"])
        let later = start.addingTimeInterval(400)
        XCTAssertEqual(session.brieflyAllowed(at: later).apps, [], "the app's five minutes are up")
        XCTAssertEqual(session.brieflyAllowed(at: later).hosts, ["x.com"])
        XCTAssertFalse(session.canAllowBriefly(key: "app:net.whatsapp.WhatsApp"))
        XCTAssertFalse(session.allowBriefly(key: "app:net.whatsapp.WhatsApp", until: later.addingTimeInterval(300)), "only once per session")
        XCTAssertEqual(session.brieflyAllowed(at: later).apps, [])
        XCTAssertTrue(session.canAllowBriefly(key: "app:com.spotify.client"))
    }
}

final class FocusAppTests: XCTestCase {
    private let allowed: Set<String> = ["com.apple.dt.Xcode", "com.google.Chrome", "com.apple.finder"]

    func testAppsOffTheFocusListAreBlockedDuringFocus() {
        let whatsapp = ActivityContext(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp")
        XCTAssertEqual(BlockEvaluator.evaluate(whatsapp, rules: [], secondsUsedToday: [:], focusAllowlist: [], focusApps: allowed), .focusApp)
        XCTAssertNil(BlockEvaluator.evaluate(whatsapp, rules: [], secondsUsedToday: [:], focusAllowlist: nil, focusApps: nil),
                     "outside focus, apps are untouched")
    }

    func testListedAppsAndBrowsersStayOpen() {
        let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
        XCTAssertNil(BlockEvaluator.evaluate(xcode, rules: [], secondsUsedToday: [:], focusAllowlist: [], focusApps: allowed))
        let chrome = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://github.com"))
        XCTAssertNil(BlockEvaluator.evaluate(chrome, rules: [], secondsUsedToday: [:], focusAllowlist: ["github.com"], focusApps: allowed))
        let offList = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://youtube.com"))
        XCTAssertEqual(BlockEvaluator.evaluate(offList, rules: [], secondsUsedToday: [:], focusAllowlist: ["github.com"], focusApps: allowed), .focus)
    }

    func testTimeInFocusAppsCountsAsFocusListTime() {
        var session = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date(), allowlist: [], allowedApps: ["com.apple.dt.Xcode"])
        session.record(300, key: "app:com.apple.dt.Xcode")
        session.record(60, key: "app:net.whatsapp.WhatsApp")
        let s = session.summary()
        XCTAssertEqual(s.focusListSeconds, 300)
        XCTAssertEqual(s.appSeconds, 60)
    }

    func testSessionWithoutAppListDecodes() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","intention":"x","plannedMinutes":60,"startedAt":0,"steps":[],"activity":{},"blockedAttempts":{},"allowlist":[]}"#
        let session = try JSONDecoder().decode(FocusSession.self, from: Data(old.utf8))
        XCTAssertNil(session.allowedApps)
    }

    func testRemovingAnActivityClearsEveryDayButKeepsRuleTime() {
        var log = UsageLog()
        let reddit = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://reddit.com"))
        let rule = BlockRule.web("reddit.com", kind: .site, dailyLimitMinutes: 10)!
        let yesterday = Date().addingTimeInterval(-86_400)
        log.record(60, context: reddit, matchedRules: [rule], on: yesterday)
        log.record(30, context: reddit, matchedRules: [rule], on: Date())
        log.recordVisit(context: reddit, on: Date())
        log.record(20, context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://github.com")), matchedRules: [], on: Date())
        log.remove(key: "web:reddit.com")
        XCTAssertEqual(log.totals(lastDays: 7, endingOn: Date()).map(\.key), ["web:github.com"])
        XCTAssertNil(log.days[UsageLog.dayKey(yesterday)])
        XCTAssertEqual(log.secondsByRule(on: Date())[rule.id], 30)
    }

    func testUnloggedActivityStillCountsTowardLimits() {
        var log = UsageLog()
        let rule = BlockRule.web("reddit.com", kind: .site, dailyLimitMinutes: 10)!
        log.record(30, context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: URL(string: "https://reddit.com")), matchedRules: [rule], on: Date(), logActivity: false)
        XCTAssertTrue(log.totals(lastDays: 1, endingOn: Date()).isEmpty)
        XCTAssertEqual(log.secondsByRule(on: Date())[rule.id], 30)
    }

    func testRemovingAnActivityFromASession() {
        var session = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date())
        session.record(60, key: "web:reddit.com"); session.record(60, key: "web:github.com")
        session.recordBlocked(key: "web:reddit.com")
        session.remove(key: "web:reddit.com")
        XCTAssertEqual(Array(session.activity.keys), ["web:github.com"])
        XCTAssertTrue(session.blockedAttempts.isEmpty)
    }
}

final class AppBlockNoticeTests: XCTestCase {
    private let whatsapp = BlockRule(kind: .app, value: "net.whatsapp.WhatsApp", displayName: "WhatsApp")

    func testBlockListNotice() {
        let notice = AppBlockNotice(reason: .rule(whatsapp), bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp")
        XCTAssertEqual(notice?.title, "WhatsApp is blocked")
        XCTAssertNil(notice?.detail)
    }

    func testLimitNoticeNamesTheMinutes() {
        var rule = whatsapp; rule.dailyLimitMinutes = 30
        let notice = AppBlockNotice(reason: .limitReached(rule), bundleID: rule.value, appName: "WhatsApp")
        XCTAssertEqual(notice?.title, "WhatsApp is done for today")
        XCTAssertEqual(notice?.message, "You used your 30 minutes. It opens again tomorrow.")
    }

    func testFocusNoticeShowsNextStepAndMinutesLeft() {
        let notice = AppBlockNotice(reason: .focusApp, bundleID: "x", appName: "WhatsApp",
                                    focus: ("Draft pricing", "Outline tiers", 41 * 60 + 5))
        XCTAssertEqual(notice?.title, "WhatsApp is paused")
        XCTAssertEqual(notice?.detail, "Next: Outline tiers · 42 min left")
        XCTAssertTrue(notice?.isFocus == true)
        let noNext = AppBlockNotice(reason: .focusApp, bundleID: "x", appName: "WhatsApp", focus: ("Draft", nil, 60))
        XCTAssertEqual(noNext?.detail, "1 min left")
    }

    func testWebsiteReasonsHaveNoAppNotice() {
        let site = BlockRule.web("reddit.com", kind: .site)!
        XCTAssertNil(AppBlockNotice(reason: .rule(site), bundleID: "com.google.Chrome", appName: "Chrome"))
        XCTAssertNil(AppBlockNotice(reason: .focus, bundleID: "com.google.Chrome", appName: "Chrome"))
    }
}

final class ThemeTests: XCTestCase {
    func testRunsAndLastNextTimeNote() {
        let triage = UUID(), base = Date(timeIntervalSince1970: 1_000_000)
        func run(_ day: Double, note: String?) -> FocusSession {
            var s = FocusSession(intention: "Triage", plannedMinutes: 30, startedAt: base.addingTimeInterval(day * 86_400))
            s.themeID = triage; s.themeKind = .chore; s.nextTime = note
            s.endedAt = s.startedAt.addingTimeInterval(1_800); return s
        }
        let oneOff = FocusSession(intention: "Other", plannedMinutes: 60, startedAt: base)
        let history = [run(0, note: "Start with P0s"), oneOff, run(1, note: "  "), run(2, note: nil)]
        XCTAssertEqual(ThemeHistory.runs(of: triage, in: history).map(\.startedAt), [2, 1, 0].map { base.addingTimeInterval($0 * 86_400) })
        XCTAssertEqual(ThemeHistory.lastNextTime(of: triage, in: history), "Start with P0s")
        XCTAssertNil(ThemeHistory.lastNextTime(of: UUID(), in: history))
    }

    func testTrimKeepsThemedRuns() {
        let theme = UUID()
        var history = (0..<5).map { FocusSession(intention: "one-off \($0)", plannedMinutes: 60, startedAt: Date(timeIntervalSince1970: Double($0))) }
        var themed = FocusSession(intention: "themed", plannedMinutes: 30, startedAt: Date(timeIntervalSince1970: -1)); themed.themeID = theme
        history.insert(themed, at: 0)
        let trimmed = ThemeHistory.trim(history, keepingOneOff: 2)
        XCTAssertEqual(trimmed.map(\.intention), ["themed", "one-off 3", "one-off 4"])
    }

    func testTrendComparesRecentRunsWithEarlierOnes() {
        let theme = UUID(), base = Date(timeIntervalSince1970: 0)
        let minutes = [45, 45, 30, 20, 25]  // oldest first
        let history = minutes.enumerated().map { i, m -> FocusSession in
            var s = FocusSession(intention: "t", plannedMinutes: 60, startedAt: base.addingTimeInterval(Double(i) * 86_400))
            s.themeID = theme; s.endedAt = s.startedAt.addingTimeInterval(Double(m * 60)); return s
        }
        let trend = ThemeHistory.trend(of: theme, in: history)
        XCTAssertEqual(trend?.recentAverageSeconds, 25 * 60)
        XCTAssertEqual(trend?.earlierAverageSeconds, 45 * 60)
        XCTAssertEqual(trend?.averageSeconds, 33 * 60)
        XCTAssertNil(ThemeHistory.trend(of: theme, in: Array(history.prefix(1))))
    }

    func testSessionWithoutThemeFieldsDecodes() throws {
        let old = FocusSession(intention: "x", plannedMinutes: 60, startedAt: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["themeID"] = nil; json["themeKind"] = nil; json["nextTime"] = nil
        let decoded = try JSONDecoder().decode(FocusSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.themeID); XCTAssertFalse(decoded.isReading)
    }

    func testLengthLabels() {
        XCTAssertEqual(FocusTheme.lengthOptions.map(Formatting.length(minutes:)), ["15m", "30m", "1h", "2h", "8h"])
    }
}

final class UsageGroupingTests: XCTestCase {
    private let names = ["com.anthropic.claudefordesktop": "Claude", "com.tinyspeck.slackmacgap": "Slack", "us.zoom.xos": "zoom.us",
                         "company.thebrowser.Browser": "Arc", "com.apple.dt.Xcode": "Xcode"]

    func testSitesMatchAppsWithTheSameName() {
        XCTAssertTrue(UsageGrouping.matches(appName: "Claude", host: "claude.ai"))
        XCTAssertTrue(UsageGrouping.matches(appName: "Slack", host: "app.slack.com"))
        XCTAssertTrue(UsageGrouping.matches(appName: "zoom.us", host: "us02web.zoom.us"))
        XCTAssertTrue(UsageGrouping.matches(appName: "Notion for Desktop", host: "notion.so"))
        XCTAssertTrue(UsageGrouping.matches(appName: "BBC", host: "www.bbc.co.uk"))
        XCTAssertFalse(UsageGrouping.matches(appName: "Microsoft Word", host: "teams.microsoft.com"))
        XCTAssertFalse(UsageGrouping.matches(appName: "Google Chrome", host: "google.com"))
        XCTAssertFalse(UsageGrouping.matches(appName: "X", host: "x.com"), "names this short match too much")
    }

    func testMatchingRowsAreFoldedTogetherByDefault() {
        let entries = [UsageEntry(key: "web:claude.ai", seconds: 600, visits: 4, appName: nil),
                       UsageEntry(key: "app:com.anthropic.claudefordesktop", seconds: 1200, visits: 2, appName: "Claude"),
                       UsageEntry(key: "web:arc.net", seconds: 60, visits: 1, appName: nil),
                       UsageEntry(key: "app:com.apple.dt.Xcode", seconds: 1500, visits: 1, appName: "Xcode")]
        let rows = UsageGrouping().apply(entries, appNames: names, excludedApps: ["company.thebrowser.Browser"])
        XCTAssertEqual(rows.map(\.title), ["Claude", "Xcode", "arc.net"])
        XCTAssertEqual(rows[0].seconds, 1800); XCTAssertEqual(rows[0].visits, 6)
        XCTAssertEqual(Set(rows[0].members.map(\.key)), ["web:claude.ai", "app:com.anthropic.claudefordesktop"])

        let webOnly = UsageGrouping().apply([entries[0]], appNames: names)
        XCTAssertEqual(webOnly.first?.title, "Claude", "a day with only the site still shows the app's row")
    }

    func testUserCanGroupAndSeparate() {
        let entries = [UsageEntry(key: "web:claude.ai", seconds: 600, visits: 4, appName: nil),
                       UsageEntry(key: "app:com.anthropic.claudefordesktop", seconds: 1200, visits: 2, appName: "Claude"),
                       UsageEntry(key: "web:console.anthropic.com", seconds: 300, visits: 1, appName: nil)]
        var grouping = UsageGrouping()
        grouping.group("web:console.anthropic.com", with: "web:claude.ai", appNames: names)
        var rows = grouping.apply(entries, appNames: names)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].title, "Claude"); XCTAssertEqual(rows[0].seconds, 2100)

        grouping.separate(rows[0])
        rows = grouping.apply(entries, appNames: names)
        XCTAssertEqual(rows.count, 3, "separating also stops the automatic match")
        XCTAssertFalse(rows.contains(where: \.isGroup))

        grouping.group("web:claude.ai", with: "app:com.anthropic.claudefordesktop", appNames: names)
        XCTAssertEqual(grouping.apply(entries, appNames: names).count, 2)
    }
}
