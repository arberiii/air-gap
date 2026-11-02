import AppKit
import SwiftUI
import AirGapCore
import os

enum FocusPhase: String, Codable { case idle, running, paused }

/// Where the focus session stands. The session only exists while one runs, so a phase without a session can't happen.
enum FocusStatus: Codable, Equatable {
    case idle
    case running(session: FocusSession, endsAt: Date)
    /// `remaining` is authoritative while paused; resuming sets a new end.
    case paused(session: FocusSession, remaining: TimeInterval)

    var phase: FocusPhase {
        switch self {
        case .idle: .idle
        case .running: .running
        case .paused: .paused
        }
    }

    /// The running or paused session. Setting it changes the session in place; it never starts or ends one.
    var session: FocusSession? {
        get {
            switch self {
            case .idle: nil
            case .running(let session, _), .paused(let session, _): session
            }
        }
        set {
            guard let newValue else { return }
            switch self {
            case .idle: break
            case .running(_, let end): self = .running(session: newValue, endsAt: end)
            case .paused(_, let left): self = .paused(session: newValue, remaining: left)
            }
        }
    }
}

/// Which assistant plans and reflects on sessions. With `.none` every coach feature is hidden.
enum CoachAgent: String, CaseIterable {
    case none, claude, codex

    /// Shown on coach buttons, like "Plan with Codex".
    var name: String {
        switch self {
        case .none: "None"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

private struct Persisted: Codable {
    var rules: [BlockRule] = []
    var usage = UsageLog()
    var focusMinutes = 60
    var focusAllowlist: [String] = []
    // Optional so a missing field decodes as empty.
    var focus: FocusStatus?
    var draft: FocusDraft?
    var review: FocusSession?
    var history: [FocusSession]?
    var focusApps: [FocusApp]?
    var ignored: [IgnoredItem]?
    var themes: [FocusTheme]?
    var grouping: UsageGrouping?
    var locks: [CommitmentLock]?
    var categories: Categorization?
    var pagePasses: [PagePass]?
}

/// An app or site the user removed from the log and asked not to track again.
struct IgnoredItem: Codable, Hashable, Identifiable {
    /// `web:<host>` or `app:<bundle id>`, like `UsageLog` keys.
    var key: String
    var title: String
    var id: String { key }
    var isWeb: Bool { ActivityKey.isWeb(key) }
    var identifier: String { ActivityKey.identifier(key) }
}

/// The last app or site blocked during the current session, so the user can let it through with one click.
struct BlockedItem: Equatable {
    /// `web:<host>` or `app:<bundle id>`, like `UsageLog` keys.
    var key: String
    var name: String
    /// The page that was blocked, reopened when the site is allowed.
    var url: URL?
    var browserBundleID: String?
    var isWeb: Bool { ActivityKey.isWeb(key) }
    var identifier: String { ActivityKey.identifier(key) }
}

/// What the user is preparing before starting a session: the intention and an optional plan from the coach.
struct FocusDraft: Codable, Equatable {
    var intention = ""
    var steps: [FocusStep] = []
    var firstMove: String?
    var encouragement: String?
    /// The coach's proposed focus list, waiting for the user to review and apply it.
    var proposal: FocusProposal?
    /// The theme picked for the next session, if any.
    var themeID: UUID?
    /// Locks the session the moment it starts. Only a setting until then: nothing is frozen.
    var lock: LockSetup?
}

/// How a session lock set before the start will behave.
struct LockSetup: Codable, Equatable {
    var override: LockOverride
    var allowsQuickCheck: Bool
}

/// A loosening change waiting for the partner's code.
struct CodePrompt: Equatable {
    var lockID: UUID
    var change: PendingChange.Kind
}

@MainActor
final class AppState: ObservableObject {
    static let focusOptions = [60, 120, 480]
    static let defaultFocusMinutes = 60
    private static let tick: TimeInterval = 2
    /// `kCGAnyInputEventType`, which Swift doesn't import: idle time counts from the last input of any kind.
    private static let anyInputEvent = CGEventType(rawValue: ~0)!
    private static let log = Logger(subsystem: "com.arberiii.airgap", category: "state")

    @Published var rules: [BlockRule] = []
    @Published var usage = UsageLog()
    @Published var focusMinutes = defaultFocusMinutes
    /// The focus list used when no theme is active.
    @Published private(set) var usualAllowlist: [String] = []
    @Published private(set) var usualApps: [FocusApp] = []
    @Published private(set) var themes: [FocusTheme] = []
    /// The theme open in the editor sheet, if any.
    @Published var themeEdit: ThemeEdit?
    @Published private(set) var lastBlocked: BlockedItem?
    @Published private(set) var focus: FocusStatus = .idle
    var phase: FocusPhase { focus.phase }
    /// Time left in the session; the selected length while idle.
    var focusRemaining: TimeInterval {
        switch focus {
        case .idle: TimeInterval(focusMinutes * 60)
        case .running(_, let end): max(end.timeIntervalSinceNow, 0)
        case .paused(_, let left): left
        }
    }
    @Published var current: ActivityContext?
    @Published var draft = FocusDraft() { didSet { save() } }
    /// The running or paused session.
    private(set) var session: FocusSession? {
        get { focus.session }
        set { focus.session = newValue }
    }
    /// A finished session waiting for the user's check-in.
    @Published var review: FocusSession?
    @Published private(set) var history: [FocusSession] = []
    @Published private(set) var coachBusy = false
    /// Kept in UserDefaults, not the state file, so deleting all data doesn't reset it. Until the user picks one, the first installed.
    var agent: CoachAgent {
        get { pickedAgent ?? [.claude, .codex].first { installedAgents.contains($0) } ?? .none }
        set { pickedAgent = newValue; Preferences.agent = newValue; coachError = nil }
    }
    @Published private var pickedAgent = Preferences.agent
    /// The assistants whose CLI was found. Looked up in the background at launch, so empty for a moment.
    @Published private(set) var installedAgents: Set<CoachAgent> = []
    @Published var coachError: String?
    /// Items never written to the log. Blocking and daily limits still apply to them.
    @Published private(set) var ignored: [IgnoredItem] = []
    /// Which apps and sites the screen time list shows as one row.
    @Published private(set) var grouping = UsageGrouping()
    /// Which category each app and site is in, for the screen time chart.
    @Published private(set) var categorization = Categorization()
    /// True while the assistant labels new items in the background. Separate from `coachBusy` so it never blocks the coach.
    @Published private(set) var labelingBusy = false
    /// True for a few seconds after an app was hidden, so the menu bar icon can show it.
    @Published private(set) var justBlocked = false
    /// Blocked pages the user asked the assistant to open, approved or not, from the last week.
    @Published private(set) var pagePasses: [PagePass] = []
    /// The page (or `app:<bundle id>`) being judged right now. One at a time, so a double submit doesn't ask twice.
    private var askingPage: String?
    /// Commitment locks, active or ended since the last tick.
    @Published private(set) var locks: [CommitmentLock] = []
    /// The scope whose lock setup is on screen, if any.
    @Published var lockSetup: LockScope?
    @Published var codePrompt: CodePrompt?
    @Published var codeFailed = false
    private let blockNotice = BlockNoticePresenter()
    private let urlHandler = URLEventHandler()
    private var justBlockedTask: Task<Void, Never>?

    private var lastKey: String?
    /// Day hourly detail was last pruned on; pruning runs on the first tick of each day.
    private var lastPruneDay: String?
    /// When a tick last wrote the state file. Other changes save at once; ticks only add seconds, so they save less often.
    private var lastTickSave = Date.distantPast
    private static let tickSaveInterval: TimeInterval = 30
    private var timer: Timer?
    /// The tick in progress. Ticks wait for the browser, so one that is still waiting makes the next ones skip.
    private var stepTask: Task<Void, Never>?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirGap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        load()
        Task { installedAgents = await AgentCoach.locate() }
        AppDelegate.isLocked = { [weak self] in self?.isLocked ?? false }
        tickLocks(Date())
        syncWatchdog()
        startTimer()
        // Ticks save at most every `tickSaveInterval`, so flush the last few seconds on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        blockNotice.onAllow = { [weak self] notice in
            guard self?.listFrozen == false else { return }
            self?.addFocusApp(FocusApp(bundleID: notice.bundleID, name: notice.appName))
            Self.bringBack(notice.bundleID)
        }
        blockNotice.onAllowBriefly = { [weak self] notice in
            self?.allowBriefly(BlockedItem(key: ActivityKey.app(notice.bundleID), name: notice.appName))
        }
        blockNotice.onAsk = { [weak self] notice, reason in self?.askForApp(notice, reason: reason) }
        urlHandler.onURL = { [weak self] in self?.handleURL($0) }
        NSAppleEventManager.shared().setEventHandler(urlHandler, andSelector: #selector(URLEventHandler.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        #if DEBUG
        previewBlockNoticeIfAsked()
        #endif
    }

    #if DEBUG
    /// `--preview-block-notice blockList|limit|focus` shows a sample card at launch, for checking the design.
    private func previewBlockNoticeIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--preview-block-notice") else { return }
        let kind: AppBlockNotice.Kind = switch args.dropFirst(i + 1).first {
        case "limit": .limitReached(minutes: 30)
        case "focus": .focus(intention: "Draft the pricing section", next: "Outline the three tiers", secondsLeft: 42 * 60)
        default: .blockList
        }
        let notice = AppBlockNotice(bundleID: "com.apple.calculator", appName: "Calculator", kind: kind)
        Task { try? await Task.sleep(for: .seconds(1)); blockNotice.show(notice) }
    }
    #endif

    var focusAllowedHosts: [String]? {
        guard phase == .running else { return nil }
        return focusAllowlist + (session?.brieflyAllowed().hosts ?? [])
    }

    /// Apps that are never hidden during focus: AirGap, Finder, browsers (their sites are filtered instead) and system screens.
    static let alwaysAllowedApps: Set<String> = BrowserBridge.bundleIDs.union([
        "com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.dock", "com.apple.Spotlight",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.ActivityMonitor", "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent", "com.apple.Passwords",
    ]).union([Bundle.main.bundleIdentifier].compactMap { $0 })

    var focusAllowedApps: Set<String>? {
        guard phase == .running else { return nil }
        return Self.alwaysAllowedApps.union(focusApps.map(\.bundleID)).union(session?.brieflyAllowed().apps ?? [])
    }

    /// Lets a blocked app or site through for a few minutes without adding it to the focus list, then brings it back.
    func allowBriefly(_ item: BlockedItem) {
        guard phase == .running, canAllowBriefly(key: item.key) else { return }
        session?.allowBriefly(key: item.key, until: Date().addingTimeInterval(TimeInterval(Preferences.quickAllowMinutes * 60)))
        clearLastBlocked(item.key)
        save()
        if item.isWeb {
            if let url = item.url, let browser = item.browserBundleID { BrowserBridge.open(url, bundleID: browser) }
        } else {
            Self.bringBack(item.identifier)
        }
    }

    /// Whether an app or site (`ActivityKey`) can still be let through for a few minutes this session.
    func canAllowBriefly(key: String) -> Bool { quickChecksAllowed && (session?.canAllowBriefly(key: key) ?? false) }

    /// Quick checks, and asking for a pass during focus: off in a reading run and under a lock that rules them out.
    private var quickChecksAllowed: Bool { !isReadingRun && runRestrictions.allowsQuickCheck }

    private func clearLastBlocked(_ key: String) { if lastBlocked?.key == key { lastBlocked = nil } }

    /// A reading theme's time is a hard cap: no pausing and nothing let through. A locked run is the same.
    var isReadingRun: Bool { session?.isReading == true }
    var canPause: Bool { !isReadingRun && !runRestrictions.isHard }
    var canEndEarly: Bool { !runRestrictions.isHard }
    /// Nothing can be added to the focus list in use: a reading run, or a lock on that list during the session.
    var listFrozen: Bool { isReadingRun || (phase != .idle && focusListLock != nil) }

    /// Adds the last blocked app or site to the focus list for good.
    func allowAlways(_ item: BlockedItem) {
        guard !listFrozen else { return }
        if item.isWeb {
            addAllowed(item.identifier)
            lastBlocked = nil
            if let url = item.url, let browser = item.browserBundleID { BrowserBridge.open(url, bundleID: browser) }
        } else {
            addFocusApp(FocusApp(bundleID: item.identifier, name: item.name))
            Self.bringBack(item.identifier)
        }
    }

    private static func bringBack(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { app.unhide(); app.activate() }
    }

    /// `airgap://allow?url=<page>&browser=<bundle id>`, from the "Allow 5 minutes" link on the browser block page.
    /// The block page only offers it with no assistant set up; otherwise a page pass is the way in.
    private func handleURL(_ string: String) {
        guard !coachEnabled, let parts = URLComponents(string: string), parts.scheme == "airgap", parts.host == "allow",
              let page = parts.queryItems?.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              page.scheme == "http" || page.scheme == "https",
              let host = URLNormalizer.host(from: page.absoluteString) else { return }
        let browser = parts.queryItems?.first { $0.name == "browser" }?.value.flatMap { BrowserBridge.isBrowser($0) ? $0 : nil }
        allowBriefly(BlockedItem(key: ActivityKey.web(host), name: host, url: page, browserBundleID: browser))
    }

    /// Apps used most today that would be hidden during focus, offered as one-click additions.
    var suggestedFocusApps: [FocusApp] {
        usage.totals(lastDays: 1, endingOn: Date()).filter { !$0.isWeb }
            .filter { entry in !Self.alwaysAllowedApps.contains(entry.identifier) && !focusApps.contains { $0.bundleID == entry.identifier } }
            .prefix(4).map { FocusApp(bundleID: $0.identifier, name: $0.title) }
    }

    func addFocusApp(_ app: FocusApp) {
        guard !focusApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        guarded(by: focusListLock, else: .addApp(app)) {
            clearLastBlocked(ActivityKey.app(app.bundleID))
            setFocusList(sites: focusAllowlist, apps: focusApps + [app])
        }
    }

    func removeFocusApp(_ app: FocusApp) {
        setFocusList(sites: focusAllowlist, apps: focusApps.filter { $0.bundleID != app.bundleID })
    }

    // MARK: Themes

    /// The theme of the running or paused session, otherwise the one picked for the next session.
    var activeTheme: FocusTheme? {
        guard let id = session?.themeID ?? (phase == .idle ? draft.themeID : nil) else { return nil }
        return themes.first { $0.id == id }
    }

    /// The focus list in use: the active theme's, or the usual one.
    var focusAllowlist: [String] { activeTheme?.sites ?? usualAllowlist }
    var focusApps: [FocusApp] { activeTheme?.apps ?? usualApps }

    /// Every change to the focus list goes here, so a theme's list and the usual list never leak into each other.
    private func setFocusList(sites: [String], apps: [FocusApp]) {
        if let theme = activeTheme, let i = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[i].sites = sites; themes[i].apps = apps
        } else {
            usualAllowlist = sites; usualApps = apps
        }
        session?.allowlist = sites
        session?.allowedApps = apps.map(\.bundleID)
        save()
    }

    var lengthOptions: [Int] { draft.themeID == nil ? Self.focusOptions : FocusTheme.lengthOptions }

    /// A blank theme that starts from the usual focus list.
    func newTheme() -> FocusTheme {
        FocusTheme(name: "", kind: .chore, minutes: 30, intention: "", checklist: [], sites: usualAllowlist, apps: usualApps)
    }

    /// Adds or replaces a theme. A theme without a name, or a locked theme, is ignored.
    func saveTheme(_ theme: FocusTheme) {
        var theme = theme
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.name.isEmpty else { return }
        guarded(by: themeLock(theme.id)) {
            if let i = themes.firstIndex(where: { $0.id == theme.id }) { themes[i] = theme } else { themes.append(theme) }
            save()
        }
    }

    /// Past runs stay in history. The theme of the running session can't be deleted.
    func deleteTheme(_ id: UUID) {
        guard session?.themeID != id else { return }
        guarded(by: themeLock(id)) {
            themes.removeAll { $0.id == id }
            if draft.themeID == id { selectTheme(nil) }
            save()
        }
    }

    /// Picks a theme for the next session and fills the draft from it; nil goes back to a one-off session.
    func selectTheme(_ id: UUID?) {
        guard phase == .idle else { return }
        guard let id, let theme = themes.first(where: { $0.id == id }) else {
            draft.themeID = nil
            if !Self.focusOptions.contains(focusMinutes) { setFocusMinutes(Self.defaultFocusMinutes) }
            return
        }
        var next = FocusDraft(intention: theme.intention, steps: theme.checklist.map { FocusStep(text: $0) })
        next.themeID = id
        draft = next
        setFocusMinutes(theme.minutes)
    }
    var menuTitle: String? { phase == .idle ? nil : Formatting.countdown(focusRemaining) }

    // MARK: Rules

    @discardableResult
    func addWebRule(_ input: String, kind: BlockKind, limit: Int?) -> Bool {
        guard let rule = BlockRule.web(input, kind: kind, dailyLimitMinutes: limit), !rules.contains(where: { $0.kind == rule.kind && $0.value == rule.value }) else { return false }
        rules.append(rule); save(); return true
    }

    func addAppRule(bundleID: String, name: String, limit: Int?) {
        guard !rules.contains(where: { $0.kind == .app && $0.value == bundleID }) else { return }
        rules.append(BlockRule(kind: .app, value: bundleID, displayName: name, dailyLimitMinutes: limit)); save()
    }

    /// Under a block list lock the removal waits for the delay or the partner's code.
    func remove(_ rule: BlockRule) {
        guarded(by: blockListLock, else: .removeRule(rule.id)) { rules.removeAll { $0.id == rule.id }; save() }
    }

    func addAllowed(_ input: String) {
        guard let host = URLNormalizer.host(from: input), !focusAllowlist.contains(host) else { return }
        guarded(by: focusListLock, else: .addSite(host)) { setFocusList(sites: focusAllowlist + [host], apps: focusApps) }
    }

    func removeAllowed(_ host: String) { setFocusList(sites: focusAllowlist.filter { $0 != host }, apps: focusApps) }

    // MARK: Focus

    func setFocusMinutes(_ minutes: Int) {
        guard phase == .idle else { return }
        focusMinutes = minutes; save()
    }

    var canStart: Bool { !draft.intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func startOrResume() {
        let now = Date()
        switch focus {
        case .running:
            return
        case .paused(let session, let left):
            focus = .running(session: session, endsAt: now.addingTimeInterval(left))
        case .idle:
            guard canStart else { return }
            var session = FocusSession(intention: draft.intention.trimmingCharacters(in: .whitespacesAndNewlines), plannedMinutes: focusMinutes,
                                       startedAt: now, steps: draft.steps, firstMove: draft.firstMove, allowlist: focusAllowlist,
                                       allowedApps: focusApps.map(\.bundleID))
            session.themeID = activeTheme?.id
            session.themeKind = activeTheme?.kind
            let endsAt = now.addingTimeInterval(TimeInterval(focusMinutes * 60))
            review = nil; lastBlocked = nil
            if let setup = draft.lock {
                locks.removeAll { $0.scope == .session }
                locks.append(CommitmentLock(scope: .session, startedAt: now, endsAt: endsAt,
                                            override: setup.override, allowsQuickCheck: setup.allowsQuickCheck))
                draft.lock = nil
            }
            focus = .running(session: session, endsAt: endsAt)
        }
        save()
        syncWatchdog()
    }

    func pause() {
        guard canPause, case .running(let session, let end) = focus else { return }
        focus = .paused(session: session, remaining: max(end.timeIntervalSinceNow, 0)); save()
    }

    /// A one-off session stopped within its first minute is a false start: no check-in, not kept in history.
    /// Themed runs always get a check-in, however short, so they show in the theme's history.
    var isFalseStart: Bool { session.map { $0.themeID == nil && Date().timeIntervalSince($0.startedAt) < 60 } ?? false }

    /// Ends the session early. Refused while a lock makes the run hard; the timer ends it when its time is up.
    func stopFocus() {
        guard canEndEarly else { return }
        finishSession()
    }

    private func finishSession() {
        locks.removeAll { $0.scope == .session }
        if var finished = session {
            let falseStart = isFalseStart
            finished.endedAt = Date()
            if !falseStart { review = finished }
            draft = FocusDraft()
        }
        focus = .idle
        if !Self.focusOptions.contains(focusMinutes) { focusMinutes = Self.defaultFocusMinutes }
        save()
        syncWatchdog()
    }

    func toggleStep(_ id: UUID) {
        guard let i = session?.steps.firstIndex(where: { $0.id == id }) else { return }
        session?.steps[i].done.toggle(); save()
    }

    func removeDraftStep(_ id: UUID) { draft.steps.removeAll { $0.id == id } }

    func toggleProposed(_ key: String) {
        draft.proposal?.skipped.formSymmetricDifference([key])
    }

    /// Items on the current focus list that applying the proposal would take off.
    var proposalRemovals: [String] {
        guard let proposal = draft.proposal else { return [] }
        return focusAllowlist.filter { !proposal.chosenSites.contains($0) }
            + focusApps.filter { app in !proposal.chosenApps.contains { $0.bundleID == app.bundleID } }.map(\.name)
    }

    /// Replaces the focus list with the ticked items of the proposal.
    func applyProposal() {
        guard phase == .idle, let proposal = draft.proposal else { return }
        guarded(by: focusListLock) {
            draft.proposal = nil
            setFocusList(sites: proposal.chosenSites, apps: proposal.chosenApps)
        }
    }

    func dismissProposal() { draft.proposal = nil }

    /// Saves the check-in and moves the session into history.
    func finishReview(useNextIntention: String? = nil) {
        guard let done = review else { return }
        history.append(done)
        history = ThemeHistory.trim(history, keepingOneOff: 200)
        review = nil
        if let next = useNextIntention { draft = FocusDraft(intention: next) }
        save()
    }

    // MARK: Coach

    /// Coach features show only when the user picked an assistant and its CLI is installed.
    var coachEnabled: Bool { installedAgents.contains(agent) }

    func requestPlan() {
        guard coachEnabled, canStart, !coachBusy else { return }
        let recent = usage.totals(lastDays: 14, endingOn: Date())
            .filter { $0.isWeb || !Self.alwaysAllowedApps.contains($0.identifier) }
        let theme = activeTheme
        let past = theme.map { ThemeHistory.runs(of: $0.id, in: history).reversed() } ?? history
        let prompt = Coach.planPrompt(intention: draft.intention, minutes: focusMinutes, allowlist: focusAllowlist, focusApps: focusApps,
                                      history: past, todayTop: usage.totals(lastDays: 1, endingOn: Date()), recent: recent, theme: theme,
                                      appNames: usage.appNames)
        let known = focusApps + recent.filter { !$0.isWeb }.map { FocusApp(bundleID: $0.identifier, name: $0.title) }
        let agent = agent
        runCoach {
            let plan: CoachPlan = try await AgentCoach.ask(prompt, schema: Coach.planSchema, with: agent)
            let steps = theme.map { Coach.mergeSteps(checklist: $0.checklist, planned: plan.steps) } ?? plan.steps
            self.draft.steps = steps.map { FocusStep(text: $0) }
            self.draft.firstMove = plan.firstMove
            self.draft.encouragement = plan.encouragement
            let proposal = Coach.proposal(from: plan, known: known, alwaysAllowed: Self.alwaysAllowedApps, rules: self.rules, history: self.history)
            self.draft.proposal = proposal.isEmpty ? nil : proposal
        }
    }

    func requestReflection() {
        guard coachEnabled, let session = review, !coachBusy else { return }
        let theme = session.themeID.flatMap { id in themes.first { $0.id == id } }
        let past = session.themeID.map { ThemeHistory.runs(of: $0, in: history).reversed() } ?? history
        let end = session.endedAt ?? Date()
        let passes = pagePasses.filter { $0.askedAt >= session.startedAt && $0.askedAt <= end }
        let prompt = Coach.reflectionPrompt(session: session, appNames: usage.appNames, history: past, theme: theme, pagePasses: passes)
        let agent = agent
        runCoach {
            let result: CoachReflection = try await AgentCoach.ask(prompt, schema: Coach.reflectionSchema, with: agent)
            guard self.review?.id == session.id else { return }
            self.review?.reflection = result.reflection
            self.reviewNextIntention = result.nextIntention
            self.save()
        }
    }

    /// The assistant's read of the screen time tab, for the number of days it covers. Not saved.
    @Published var usageSummary: (days: Int, summary: CoachUsageSummary)?

    func requestUsageSummary(days: Int) {
        guard coachEnabled, !coachBusy else { return }
        let prompt = Coach.usageSummaryPrompt(usage: usage, days: days, rules: rules, allowlist: usualAllowlist, focusApps: usualApps,
                                              history: history, grouping: grouping, excludedApps: BrowserBridge.bundleIDs)
        let agent = agent
        runCoach { self.usageSummary = (days, try await AgentCoach.ask(prompt, schema: Coach.usageSummarySchema, with: agent)) }
    }

    /// The coach's suggestion for the next session, offered on the check-in screen.
    @Published var reviewNextIntention: String?

    private func runCoach(_ work: @escaping @MainActor () async throws -> Void) {
        coachBusy = true; coachError = nil
        Task { @MainActor in
            do { try await work() } catch { self.coachError = error.localizedDescription }
            self.coachBusy = false
        }
    }

    /// Ends the session when its time is up; until then refreshes the countdown, which is computed from the end.
    private func updateRemaining() {
        guard case .running(_, let end) = focus else { return }
        if end <= Date() { finishSession() } else { objectWillChange.send() }
    }

    // MARK: Tracking + blocking

    /// Erases one app or site from screen time and from the current and past focus sessions.
    /// With `stopTracking` it is also never logged again.
    func removeFromLog(_ entry: UsageEntry, stopTracking: Bool) {
        if entry.isGroup { return entry.members.forEach { removeFromLog($0, stopTracking: stopTracking) } }
        usage.remove(key: entry.key)
        categorization.forget(key: entry.key)
        session?.remove(key: entry.key)
        review?.remove(key: entry.key)
        for i in history.indices { history[i].remove(key: entry.key) }
        if lastKey == entry.key { lastKey = nil }
        if stopTracking, !ignored.contains(where: { $0.key == entry.key }) {
            ignored.append(IgnoredItem(key: entry.key, title: entry.title))
        }
        save()
    }

    /// Screen time rows for the last `days`, with grouped apps and sites folded together. Browsers are never matched to a site.
    func usageRows(lastDays days: Int, sortedBy order: UsageSort) -> [UsageEntry] {
        grouping.apply(usage.totals(lastDays: days, endingOn: Date()), appNames: usage.appNames, excludedApps: BrowserBridge.bundleIDs, sortedBy: order)
    }

    func group(_ entry: UsageEntry, with target: UsageEntry) {
        grouping.group(entry.key, with: target.key, appNames: usage.appNames, excludedApps: BrowserBridge.bundleIDs)
        save()
    }

    func separate(_ entry: UsageEntry) { grouping.separate(entry); save() }

    /// Puts a row, and every app and site grouped into it, in a category.
    func setCategory(_ id: String, for entry: UsageEntry) {
        categorization.setUserCategory(id, for: [entry.key] + entry.parts.map(\.key))
        save()
    }

    func addCategory(named name: String) { categorization.addCategory(named: name); save() }
    func renameCategory(_ id: String, to name: String) { categorization.renameCategory(id, to: name); save() }
    func deleteCategory(_ id: String) { categorization.deleteCategory(id); save() }

    /// Today by hour, or the last `days` by day, totaled by category.
    func categoryChart(lastDays days: Int) -> [CategorySlice] {
        days == 1
            ? UsageChart.hourly(usage, on: Date(), grouping: grouping, categories: categorization, excludedApps: BrowserBridge.bundleIDs)
            : UsageChart.daily(usage, lastDays: days, endingOn: Date(), grouping: grouping, categories: categorization,
                               excludedApps: BrowserBridge.bundleIDs)
    }

    /// Asks the assistant to categorize up to 50 recent apps and sites nothing has labeled yet. Only names are sent. Failures are ignored.
    func labelCategoriesIfNeeded() {
        guard coachEnabled, !labelingBusy else { return }
        let batch = usage.totals(lastDays: 7, endingOn: Date()).filter { categorization.needsLabel($0.key) }.prefix(50)
        guard !batch.isEmpty else { return }
        let keys = batch.map(\.key)
        categorization.beginLabeling(keys)
        let prompt = Coach.categoryPrompt(items: batch.map { ($0.key, $0.title) }, categories: categorization.categories)
        let ids = categorization.categories.map(\.id)
        let agent = agent
        labelingBusy = true
        Task { @MainActor in
            defer { self.labelingBusy = false }
            guard let answer: CoachCategoryAnswer = try? await AgentCoach.ask(prompt, schema: Coach.categorySchema(ids: ids), with: agent) else { return self.categorization.cancelLabeling(keys) }
            let valid = Set(self.categorization.categories.map(\.id))
            self.categorization.applyAssistantLabels(Coach.categoryLabels(answer, asked: keys, validIDs: valid), asked: keys)
            self.save()
        }
    }

    func trackAgain(_ item: IgnoredItem) { ignored.removeAll { $0.key == item.key }; save() }

    /// Removes every stored record: screen time, rules, focus lists and sessions. The not-tracked list is kept.
    func deleteAllData() {
        timer?.invalidate(); timer = nil; stepTask?.cancel()
        rules = []; usage = UsageLog(); grouping = UsageGrouping(); categorization = Categorization(); usualAllowlist = []; usualApps = []; themes = []; lastBlocked = nil
        pagePasses = []
        locks = []; lockSetup = nil; codePrompt = nil; codeFailed = false
        syncWatchdog()
        focus = .idle; focusMinutes = Self.defaultFocusMinutes
        draft = FocusDraft(); review = nil; history = []; reviewNextIntention = nil; coachError = nil
        current = nil; lastKey = nil
        try? FileManager.default.removeItem(at: fileURL)
        save()
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stepTask == nil else { return }
                self.stepTask = Task { await self.step(); self.stepTask = nil }
            }
        }
    }

    private func step() async {
        tickLocks(Date())
        updateRemaining()
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID
        let isBrowser = BrowserBridge.isBrowser(bundleID)
        let url = isBrowser ? await BrowserBridge.currentURL(bundleID: bundleID) : nil
        let fields = isBrowser && (url == nil || url?.scheme == "data") ? await BrowserBridge.pendingAsk(bundleID: bundleID) : nil
        // Delete all data may have run while the browser answered.
        guard !Task.isCancelled else { return }
        if let fields, let parts = URLComponents(string: "airgap://ask?" + fields) { askForPage(parts) }
        let context = ActivityContext(bundleID: bundleID, appName: name, url: url)
        current = context

        let now = Date()
        if UsageLog.dayKey(now) != lastPruneDay {
            usage.prune(now: now); lastPruneDay = UsageLog.dayKey(now)
            pagePasses.removeAll { now.timeIntervalSince($0.askedAt) > 7 * 86_400 }
        }
        let key = UsageLog.key(for: context)
        let logged = !ignored.contains { $0.key == key }
        if key != lastKey { if logged { usage.recordVisit(context: context, on: now) }; lastKey = key }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEvent)
        if idle < TimeInterval(Preferences.idleMinutes * 60) {
            usage.record(Self.tick, context: context, matchedRules: rules.filter { $0.matches(context) }, on: now, logActivity: logged)
            if phase == .running, logged { session?.record(Self.tick, key: key) }
        }

        if let reason = blockReason(for: context, now: now) {
            await enforce(reason, on: app, context: context)
            lastTickSave = .distantPast
        }
        if now.timeIntervalSince(lastTickSave) >= Self.tickSaveInterval { save(); lastTickSave = now }
    }

    /// Why `context` is blocked right now, if it is. Without `checkApps` only pages are judged, not the app showing them.
    private func blockReason(for context: ActivityContext, now: Date = Date(), checkApps: Bool = true) -> BlockReason? {
        BlockEvaluator.evaluate(context, rules: rules, secondsUsedToday: usage.secondsByRule(on: now), focusAllowlist: focusAllowedHosts,
                                focusApps: checkApps ? focusAllowedApps : nil, pagePasses: pagePasses.filter { $0.isActive(at: now) })
    }

    private func enforce(_ reason: BlockReason, on app: NSRunningApplication, context: ActivityContext) async {
        if context.url != nil {
            if reason == .focus, let host = context.webHost {
                session?.recordBlocked(key: ActivityKey.web(host))
                lastBlocked = BlockedItem(key: ActivityKey.web(host), name: host, url: context.url, browserBundleID: context.bundleID)
            }
            let offer = blockPageOffer(for: reason, context: context, title: await BrowserBridge.currentTitle(bundleID: context.bundleID))
            BrowserBridge.redirect(bundleID: context.bundleID, message: reason.message, focus: focusLine(for: reason), offer: offer, blockedURL: context.url)
        } else if reason.hidesApp {
            app.hide()
            if reason == .focusApp {
                session?.recordBlocked(key: ActivityKey.app(context.bundleID))
                lastBlocked = BlockedItem(key: ActivityKey.app(context.bundleID), name: context.appName)
            }
            announceHidden(reason, context: context)
        }
    }

    /// With an assistant set up, any blocked page can be asked for; without one, focus keeps the old few-minutes link for the site.
    private func blockPageOffer(for reason: BlockReason, context: ActivityContext, title: String?) -> BrowserBridge.Offer {
        guard coachEnabled else {
            let canAllow = reason == .focus && context.webHost.map { canAllowBriefly(key: ActivityKey.web($0)) } == true
            return canAllow ? .allowMinutes(Preferences.quickAllowMinutes) : .none
        }
        guard canAskForPage(reason) else { return .none }
        return .ask(agentName: agent.name, title: title, passesLeft: passesLeft)
    }

    /// The same ask for a hidden app, from the reason box on its card. On a yes the app comes back for `PagePass.minutes`.
    private func askForApp(_ notice: AppBlockNotice, reason: String) {
        let answer = { [weak self] (approved: Bool, reply: String) -> Void in self?.blockNotice.showAnswer(approved: approved, reply: reply) }
        guard askingPage == nil, coachEnabled else { return answer(false, "Another ask is still waiting for an answer.") }
        guard let blocked = blockReason(for: ActivityContext(bundleID: notice.bundleID, appName: notice.appName)) else {
            Self.bringBack(notice.bundleID)
            return answer(true, "\(notice.appName) isn't blocked anymore.")
        }
        guard canAskForPage(blocked) else { return answer(false, "No passes left right now.") }
        let prompt = Coach.appPassPrompt(appName: notice.appName, bundleID: notice.bundleID, reason: reason, blockedBecause: blocked.message,
                                         focus: blocked == .focusApp ? session?.intention : nil, earlier: passesToday)
        judgePass(page: PagePass.app(notice.bundleID), title: notice.appName, reason: reason, prompt: prompt, blocked: blocked) { approved, reply in
            answer(approved, reply)
            guard approved else { return }
            self.clearLastBlocked(ActivityKey.app(notice.bundleID))
            Self.bringBack(notice.bundleID)
        }
    }

    /// `url=<page>&browser=<bundle id>&title=<tab title>&reason=<typed>`, left by the block page's form in the tab's title.
    /// The assistant decides; on a yes only that page opens, for `PagePass.minutes`.
    private func askForPage(_ parts: URLComponents) {
        let value = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        guard askingPage == nil, coachEnabled,
              let url = value("url").flatMap(URL.init(string:)), let browser = value("browser"), BrowserBridge.isBrowser(browser),
              let page = PagePass.page(from: url) else { return }
        let reason = (value("reason") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = value("title").flatMap { $0.isEmpty ? nil : $0 }
        let context = ActivityContext(bundleID: browser, appName: browser, url: url)
        guard let blocked = blockReason(for: context, checkApps: false) else { return BrowserBridge.open(url, bundleID: browser) }
        let focus = focusLine(for: blocked)
        let showPage = { [weak self] (note: String) in
            guard let self else { return }
            BrowserBridge.redirect(bundleID: browser, message: blocked.message, focus: focus,
                                   offer: self.blockPageOffer(for: blocked, context: context, title: title), blockedURL: url, note: note,
                                   overBlockPage: true)
        }
        guard canAskForPage(blocked) else { return showPage("No page passes left right now.") }
        guard reason.count >= PagePass.minReasonLength else { return showPage("Say a bit more about why you need this page.") }

        BrowserBridge.redirect(bundleID: browser, message: blocked.message, focus: focus, note: "Asking \(agent.name)…")
        let prompt = Coach.pagePassPrompt(url: url, title: title, reason: reason, blockedBecause: blocked.message, focus: focus?.intention,
                                          earlier: passesToday)
        judgePass(page: page, title: title, reason: reason, prompt: prompt, blocked: blocked) { approved, reply in
            guard approved else { return showPage(reply) }
            BrowserBridge.open(url, bundleID: browser, overBlockPage: true)
        }
    }

    /// Asks the assistant whether to let one page or app through, records the answer as a pass and hands it to `finish`.
    /// Holds the one-at-a-time slot until then. A yes only counts if a pass is still left when it arrives;
    /// an assistant that couldn't answer is a no, with the reason as the reply.
    private func judgePass(page: String, title: String?, reason: String, prompt: String, blocked: BlockReason,
                           finish: @escaping @MainActor (_ approved: Bool, _ reply: String) -> Void) {
        askingPage = page
        let agent = agent
        Task { @MainActor in
            defer { self.askingPage = nil }
            let verdict: CoachPageVerdict
            do { verdict = try await AgentCoach.ask(prompt, schema: Coach.pageVerdictSchema, with: agent) } catch {
                return finish(false, "\(agent.name) couldn't answer: \(error.localizedDescription)")
            }
            let asked = Date()
            let approved = verdict.approve && self.canAskForPage(blocked)
            self.pagePasses.append(PagePass(page: page, title: title, reason: reason, approved: approved, reply: verdict.reply, askedAt: asked,
                                            until: approved ? asked.addingTimeInterval(TimeInterval(PagePass.minutes * 60)) : nil))
            self.save()
            finish(approved, verdict.reply)
        }
    }

    private var passesToday: [PagePass] { pagePasses.filter { Calendar.current.isDateInToday($0.askedAt) } }
    private var passesLeft: Int { PagePass.dailyLimit - PagePass.approvedToday(pagePasses, now: Date()) }

    /// Asking needs a pass left today and no lock that rules out quick checks. Focus also stays shut during a reading run.
    private func canAskForPage(_ reason: BlockReason) -> Bool {
        guard passesLeft > 0 else { return false }
        switch reason {
        case .focus, .focusApp: return quickChecksAllowed
        case .rule, .limitReached: return blockListLock?.allowsQuickCheck ?? true
        }
    }

    /// The focus intention and next step shown on the browser block page, during a focus block only.
    private func focusLine(for reason: BlockReason) -> (intention: String, next: String?)? {
        guard reason == .focus, let session else { return nil }
        return (session.intention, session.nextStep?.text ?? session.firstMove)
    }

    /// Tells the user why the app disappeared: a floating card plus a moment of a blocked icon in the menu bar.
    private func announceHidden(_ reason: BlockReason, context: ActivityContext) {
        let focus = session.map { (intention: $0.intention, next: $0.nextStep?.text ?? $0.firstMove, secondsLeft: focusRemaining) }
        guard var notice = AppBlockNotice(reason: reason, bundleID: context.bundleID, appName: context.appName, focus: focus) else { return }
        notice.canAllowBriefly = canAllowBriefly(key: ActivityKey.app(context.bundleID))
        notice.canAddToList = !listFrozen
        if coachEnabled, canAskForPage(reason) {
            notice.askAgentName = agent.name
            notice.passesLeft = passesLeft
        }
        blockNotice.show(notice)
        justBlocked = true
        justBlockedTask?.cancel()
        justBlockedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.justBlocked = false }
        }
    }

    // MARK: Locks

    var isLocked: Bool { !LockPolicy.active(locks, at: Date()).isEmpty }
    var blockListLock: CommitmentLock? { LockPolicy.lock(locks, scope: .blockList, at: Date()) }
    var sessionLock: CommitmentLock? { LockPolicy.lock(locks, scope: .session, at: Date()) }
    func themeLock(_ id: UUID) -> CommitmentLock? { LockPolicy.lock(locks, scope: .theme(id), at: Date()) }
    func isThemeLocked(_ id: UUID) -> Bool { themeLock(id) != nil }
    /// The lock on the focus list in use: the active theme's, or the session lock while a session runs.
    var focusListLock: CommitmentLock? { LockPolicy.focusListLock(locks, theme: activeTheme?.id, sessionUsesList: phase != .idle, at: Date()) }
    var runRestrictions: RunRestrictions {
        guard phase != .idle else { return .none }
        return LockPolicy.run(locks, sessionTheme: session?.themeID, at: Date())
    }

    /// Sets a lock. A session lock while idle is kept on the draft and starts with the session; while running it ends with it.
    func lock(_ scope: LockScope, days: Int?, override: LockOverride, allowsQuickCheck: Bool) {
        let now = Date()
        guard LockPolicy.lock(locks, scope: scope, at: now) == nil else { return }
        let endsAt: Date
        switch scope {
        case .session:
            guard case .running(_, let end) = focus else {
                if phase == .idle { draft.lock = LockSetup(override: override, allowsQuickCheck: allowsQuickCheck) }
                return
            }
            endsAt = end
        case .theme, .blockList:
            guard let days else { return }
            endsAt = now.addingTimeInterval(TimeInterval(days) * 86_400)
        }
        locks.removeAll { $0.scope == scope }
        locks.append(CommitmentLock(scope: scope, startedAt: now, endsAt: endsAt, override: override, allowsQuickCheck: allowsQuickCheck))
        if case .theme(let id) = scope, draft.themeID == id { draft.lock = nil }
        save()
        syncWatchdog()
    }

    func removeDraftLock() { draft.lock = nil }

    /// Every edit a lock can stand in front of goes through here. Without a lock `change` runs at once. Under one, a change
    /// the lock can let through later (`pending`) is queued or put to the partner; anything else is refused.
    private func guarded(by lock: CommitmentLock?, else pending: PendingChange.Kind? = nil, _ change: () -> Void) {
        guard let lock else { return change() }
        if let pending { requestChange(pending, on: lock) }
    }

    /// A loosening change under a lock: queued under a delay, or asked of the partner. Session locks under a delay take nothing.
    func requestChange(_ kind: PendingChange.Kind, on lock: CommitmentLock) {
        guard let i = locks.firstIndex(where: { $0.id == lock.id }) else { return }
        switch lock.override {
        case .delay:
            guard locks[i].queue(kind, at: Date()) != nil else { return }
            save()
        case .partner:
            codeFailed = false
            codePrompt = CodePrompt(lockID: lock.id, change: kind)
        }
    }

    func cancelPending(_ id: UUID, on lockID: UUID) {
        guard let i = locks.firstIndex(where: { $0.id == lockID }) else { return }
        locks[i].cancel(id); save()
    }

    /// The partner's answer: the right code applies the change at once.
    func confirmCode(_ code: String) {
        guard let prompt = codePrompt, let lock = locks.first(where: { $0.id == prompt.lockID }) else { codePrompt = nil; return }
        guard case .partner(let partner) = lock.override, partner.matches(code) else { codeFailed = true; return }
        codePrompt = nil; codeFailed = false
        apply(prompt.change, lockID: lock.id)
    }

    func dismissCodePrompt() { codePrompt = nil; codeFailed = false }

    private func apply(_ kind: PendingChange.Kind, lockID: UUID) {
        guard let lock = locks.first(where: { $0.id == lockID }) else { return }
        switch kind {
        case .unlock:
            locks.removeAll { $0.id == lockID }
        case .removeRule(let id):
            rules.removeAll { $0.id == id }
        case .addSite, .addApp:
            // The list the lock covers: the theme's own, or the list in use for a session lock.
            var sites: [String], apps: [FocusApp], themeIndex: Int?
            if case .theme(let themeID) = lock.scope {
                guard let i = themes.firstIndex(where: { $0.id == themeID }) else { break }
                themeIndex = i; sites = themes[i].sites; apps = themes[i].apps
            } else {
                sites = focusAllowlist; apps = focusApps
            }
            if case .addSite(let host) = kind, !sites.contains(host) { sites.append(host) }
            if case .addApp(let app) = kind, !apps.contains(where: { $0.bundleID == app.bundleID }) { apps.append(app) }
            if let i = themeIndex, activeTheme?.id != themes[i].id { themes[i].sites = sites; themes[i].apps = apps }
            else { setFocusList(sites: sites, apps: apps) }
        }
        save()
        syncWatchdog()
    }

    /// Applies due changes and drops ended locks. Runs on every tick and at launch.
    private func tickLocks(_ now: Date) {
        var changed = false
        // Ended locks too: a change due at the lock's end must land, not vanish with the lock.
        for lock in locks {
            guard let i = locks.firstIndex(where: { $0.id == lock.id }) else { continue }
            let due = locks[i].takeDue(at: now)
            if !due.isEmpty { changed = true }
            for kind in due { apply(kind, lockID: lock.id) }
        }
        if locks.contains(where: { !$0.isActive(at: now) }) { locks.removeAll { !$0.isActive(at: now) }; changed = true }
        if changed { save() }
        if changed || isLocked != (watchdogUntil != nil) { syncWatchdog() }
    }

    /// The end of the latest active lock the watchdog was last told about.
    private var watchdogUntil: Date?

    /// Keeps the LaunchAgent loaded exactly while a lock is active, with the latest lock's end as its stop time.
    private func syncWatchdog() {
        watchdogUntil = LockPolicy.active(locks, at: Date()).map(\.endsAt).max()
        Watchdog.sync(until: watchdogUntil)
    }

    /// One line per active lock, for the Delete all data confirmation.
    var lockDescriptions: [String] {
        LockPolicy.active(locks, at: Date()).map { lock in
            let until = lock.endsAt.formatted(date: .abbreviated, time: .shortened)
            switch lock.scope {
            case .session: return "This session is locked until \(until)."
            case .blockList: return "The block list is locked until \(until)."
            case .theme(let id): return "Theme \u{201C}\(themes.first { $0.id == id }?.name ?? "deleted")\u{201D} is locked until \(until)."
            }
        }
    }

    // MARK: Persistence

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let saved: Persisted
        do {
            saved = try JSONDecoder().decode(Persisted.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it with empty state on the next save.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Self.log.error("Could not read \(self.fileURL.path, privacy: .public), moved it to \(aside.lastPathComponent, privacy: .public): \(error)")
            return
        }
        rules = saved.rules
        usage = saved.usage
        usualAllowlist = saved.focusAllowlist
        usualApps = saved.focusApps ?? []
        themes = saved.themes ?? []
        focusMinutes = FocusTheme.lengthOptions.contains(saved.focusMinutes) ? saved.focusMinutes : Self.defaultFocusMinutes
        focus = saved.focus ?? .idle
        draft = saved.draft ?? FocusDraft()
        review = saved.review
        history = saved.history ?? []
        ignored = saved.ignored ?? []
        grouping = saved.grouping ?? UsageGrouping()
        locks = saved.locks ?? []
        categorization = saved.categories ?? Categorization()
        pagePasses = saved.pagePasses ?? []
        updateRemaining()
    }

    private var loading = false

    private func save() {
        guard !loading else { return }
        let snapshot = Persisted(rules: rules, usage: usage, focusMinutes: focusMinutes, focusAllowlist: usualAllowlist,
                                 focus: focus, draft: draft, review: review, history: history, focusApps: usualApps,
                                 ignored: ignored, themes: themes, grouping: grouping, locks: locks,
                                 categories: categorization, pagePasses: pagePasses)
        do {
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Could not save state: \(error)")
        }
    }
}

/// Receives `airgap://` links. Apple event handlers need an Objective-C target.
private final class URLEventHandler: NSObject {
    var onURL: @MainActor (String) -> Void = { _ in }

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        MainActor.assumeIsolated { onURL(url) }
    }
}
