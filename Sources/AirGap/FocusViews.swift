import SwiftUI
import AirGapCore

struct FocusView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.phase != .idle {
            FocusRunningView()
        } else if state.review != nil {
            CheckInView()
        } else {
            FocusComposeView()
        }
    }
}

/// Before a session: decide what this session is for, optionally plan it with the assistant.
private struct FocusComposeView: View {
    @EnvironmentObject var state: AppState
    @State private var input = ""
    @State private var listExpanded = false
    @State private var notebookTheme: FocusTheme?

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ThemeChipsRow(notebook: $notebookTheme)
                    if let theme = state.activeTheme { LastTimePanel(theme: theme, notebook: $notebookTheme) }
                    Text("What will you get done in this session?").font(.headline)
                    TextField("Draft the pricing section", text: $state.draft.intention, axis: .vertical)
                        .lineLimit(2...3).textFieldStyle(.roundedBorder)
                    Picker("", selection: Binding(get: { state.focusMinutes }, set: state.setFocusMinutes)) {
                        ForEach(state.lengthOptions, id: \.self) { Text(Formatting.length(minutes: $0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    composeLockLine

                    if state.coachEnabled {
                        CoachButton(title: state.draft.steps.isEmpty ? "Plan with \(state.agent.name)" : "Plan again", disabled: !state.canStart,
                                    action: state.requestPlan)

                        if let note = state.draft.encouragement { Text(note).font(.callout).italic().foregroundStyle(.secondary) }
                        if let first = state.draft.firstMove {
                            Label("Start with: \(first)", systemImage: "figure.walk").font(.callout)
                        }
                    }
                    ForEach(state.draft.steps) { step in
                        HStack(alignment: .top) {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            Text(step.text).font(.callout)
                            Spacer()
                            Button { state.removeDraftStep(step.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove step")
                        }
                    }
                    if state.coachEnabled, let proposal = state.draft.proposal { ProposalView(proposal: proposal) }

                    DisclosureGroup(isExpanded: $listExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sites").font(.caption.bold()).foregroundStyle(.secondary)
                            HStack {
                                TextField("github.com", text: $input).textFieldStyle(.roundedBorder).onSubmit(add)
                                Button("Add", action: add)
                            }
                            ForEach(state.focusAllowlist, id: \.self) { host in
                                HStack {
                                    ActivityIcon(source: .web(host))
                                    Text(host); Spacer()
                                    Button { state.removeAllowed(host) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                            }
                            if let lock = state.focusListLock {
                                ForEach(lock.pending) { change in
                                    if case .addSite(let host) = change.kind {
                                        HStack { ActivityIcon(source: .web(host)); Text(host).foregroundStyle(.secondary); Spacer(); PendingNote(change: change, lockID: lock.id) }
                                    }
                                }
                            }
                            HStack {
                                Text("Apps").font(.caption.bold()).foregroundStyle(.secondary)
                                Spacer()
                                Button("Choose app…", action: chooseApp).controlSize(.small)
                            }
                            Text("Other apps are hidden while focusing. Finder and browsers always stay open.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(state.focusApps) { app in
                                HStack {
                                    ActivityIcon(source: .app(app.bundleID))
                                    Text(app.name); Spacer()
                                    Button { state.removeFocusApp(app) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                            }
                            if let lock = state.focusListLock {
                                ForEach(lock.pending) { change in
                                    if case .addApp(let app) = change.kind {
                                        HStack { ActivityIcon(source: .app(app.bundleID)); Text(app.name).foregroundStyle(.secondary); Spacer(); PendingNote(change: change, lockID: lock.id) }
                                    }
                                }
                            }
                            let suggested = state.suggestedFocusApps
                            if !suggested.isEmpty {
                                Text("Used today:").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    ForEach(suggested) { app in
                                        Button { state.addFocusApp(app) } label: { Label(app.name, systemImage: "plus").lineLimit(1) }
                                            .controlSize(.small)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("\(state.activeTheme == nil ? "Focus list" : "Theme focus list"): \(state.focusAllowlist.count) sites, \(state.focusApps.count) apps")
                    }.font(.callout)

                    if !state.history.isEmpty {
                        DisclosureGroup("Recent sessions") {
                            ForEach(state.history.suffix(5).reversed()) { past in
                                HStack(alignment: .top) {
                                    OutcomeIcon(outcome: past.outcome)
                                    Text(past.intention).lineLimit(2)
                                    Spacer()
                                    Text(past.startedAt, format: .dateTime.weekday(.abbreviated).hour().minute()).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.font(.callout)
                    }
                }
                .padding(.horizontal, 2)
            }
            Button {
                state.startOrResume()
            } label: {
                HStack(spacing: 4) {
                    if state.draft.lock != nil { Image(systemName: "lock.fill") }
                    Text(state.draft.lock == nil ? "Start focusing" : "Start locked")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!state.canStart)
        }
        .sheet(item: $notebookTheme) { ThemeNotebookSheet(theme: $0).environmentObject(state) }
    }

    /// One Lock control: for a one-off session the session lock; for a theme, a choice between the session and the theme.
    @ViewBuilder private var composeLockLine: some View {
        if let theme = state.activeTheme {
            if state.isThemeLocked(theme.id) {
                LockStatusLine(scope: .theme(theme.id))
            } else if state.draft.lock != nil {
                LockStatusLine(scope: .session)
            } else {
                Menu {
                    Button("This session") { state.lockSetup = .session }
                    Button("The theme") { state.lockSetup = .theme(theme.id) }
                } label: { Label("Lock", systemImage: "lock") }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LockStatusLine(scope: .session)
        }
    }

    private func add() { state.addAllowed(input); input = "" }

    private func chooseApp() { if let app = chooseApplication() { state.addFocusApp(app) } }
}

/// During a session: the intention stays in front of the user, with the plan to tick off.
private struct FocusRunningView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            if let session = state.session {
                VStack(spacing: 2) {
                    Text("Focusing on").font(.caption).foregroundStyle(.secondary)
                    Text(session.intention).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(3)
                }
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 7)
                    Circle().trim(from: 0, to: state.focusRemaining / TimeInterval(session.plannedMinutes * 60))
                        .stroke(.green, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text(Formatting.countdown(state.focusRemaining)).font(.system(size: 28, weight: .bold)).monospacedDigit()
                }
                .frame(width: 130, height: 130)
                HStack {
                    if state.canPause || state.phase == .paused {
                        Button(state.phase == .running ? "Pause" : "Resume") {
                            state.phase == .running ? state.pause() : state.startOrResume()
                        }.buttonStyle(.borderedProminent)
                    }
                    if state.canEndEarly {
                        if state.isFalseStart {
                            Button("Discard", action: state.stopFocus)
                                .help("Sessions ended in the first minute aren't saved to history")
                        } else {
                            Button("End session", action: state.stopFocus)
                        }
                    }
                }
                if let theme = session.themeID, state.isThemeLocked(theme) {
                    LockStatusLine(scope: .theme(theme))
                } else {
                    LockStatusLine(scope: .session)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let first = session.firstMove, !session.steps.contains(where: \.done) {
                            Label("Start with: \(first)", systemImage: "figure.walk").font(.callout)
                        }
                        ForEach(session.steps) { step in
                            Button { state.toggleStep(step.id) } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle").foregroundStyle(step.done ? .green : .secondary)
                                    Text(step.text).strikethrough(step.done).foregroundStyle(step.done ? .secondary : .primary)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let blocked = state.lastBlocked {
                    HStack {
                        ActivityIcon(key: blocked.key)
                        Text("\(blocked.isWeb ? "Blocked" : "Hid") \(blocked.name).").font(.callout).lineLimit(1)
                        Spacer()
                        if state.canAllowBriefly(key: blocked.key) {
                            Button("\(Preferences.quickAllowMinutes) min") { state.allowBriefly(blocked) }
                                .help("Allow \(blocked.name) for a quick check, once per session")
                        }
                        if !state.listFrozen {
                            Button("Add to list") { state.allowAlways(blocked) }
                                .help("Add \(blocked.name) to your focus list")
                        }
                    }.controlSize(.small)
                    .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                let blocked = session.blockedAttempts.values.reduce(0, +)
                if blocked > 0 {
                    Text("Pulled away \(blocked) time\(blocked == 1 ? "" : "s") so far. You came back each time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// After a session: a short, honest check-in, and an optional reflection from the assistant.
private struct CheckInView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let review = state.review {
            let summary = review.summary(appNames: state.usage.appNames)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session done").font(.caption).foregroundStyle(.secondary)
                        Text(review.intention).font(.title3.bold())
                    }
                    HStack {
                        Stat(value: Formatting.duration(summary.totalSeconds), label: "active")
                        Stat(value: Formatting.duration(summary.focusListSeconds), label: "on focus list")
                        Stat(value: "\(summary.blockedAttempts)", label: "pulled away")
                    }
                    if !summary.top.isEmpty {
                        Text("Time went to " + summary.top.prefix(3).map { "\($0.name) \(Formatting.duration($0.seconds))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !review.steps.isEmpty {
                        Text("\(review.steps.filter(\.done).count) of \(review.steps.count) steps done").font(.caption).foregroundStyle(.secondary)
                    }

                    Text(review.isReading ? "Was it worth it?" : "Did you move it forward?").font(.headline)
                    HStack {
                        ForEach(SessionOutcome.allCases, id: \.self) { outcome in
                            Button(outcome.label) { state.review?.outcome = outcome }
                                .buttonStyle(.bordered).tint(review.outcome == outcome ? .accentColor : nil)
                                .background(review.outcome == outcome ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    TextField(review.isReading ? "What was worth it? Any takeaway?" : "What got in the way, or what comes next?",
                              text: Binding(get: { state.review?.note ?? "" }, set: { state.review?.note = $0 }), axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                    if review.themeID != nil {
                        TextField("Anything to remember for next time?",
                                  text: Binding(get: { state.review?.nextTime ?? "" }, set: { state.review?.nextTime = $0 }), axis: .vertical)
                            .lineLimit(1...3).textFieldStyle(.roundedBorder)
                    }

                    if state.coachEnabled {
                        CoachButton(title: "Reflect with \(state.agent.name)", disabled: review.outcome == nil, action: state.requestReflection)
                    }
                    if let reflection = review.reflection {
                        Text(reflection).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        if let next = state.reviewNextIntention {
                            Button { state.finishReview(useNextIntention: next) } label: {
                                Label("Next: \(next)", systemImage: "arrow.right.circle").lineLimit(2).multilineTextAlignment(.leading)
                            }.help("Save and use this as your next intention")
                        }
                        Spacer()
                        Button("Save") { state.finishReview() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct OutcomeIcon: View {
    let outcome: SessionOutcome?

    var body: some View {
        switch outcome {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partly: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .notReally: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case nil: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

/// The focus list the assistant proposes for this session. The user ticks what to keep, then applies it or keeps their own list.
private struct ProposalView: View {
    @EnvironmentObject var state: AppState
    let proposal: FocusProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.agent.name) suggests only these for this session").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(proposal.sites, id: \.self) { host in
                row(key: ActivityKey.web(host), source: .web(host), name: host, isNew: !state.focusAllowlist.contains(host))
            }
            ForEach(proposal.apps) { app in
                row(key: ActivityKey.app(app.bundleID), source: .app(app.bundleID), name: app.name,
                    isNew: !state.focusApps.contains { $0.bundleID == app.bundleID })
            }
            let removals = state.proposalRemovals
            if !removals.isEmpty {
                Text("Takes off your list: " + removals.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if state.focusListLock == nil {
                    Button("Use this focus list", action: state.applyProposal).buttonStyle(.borderedProminent)
                } else {
                    Text("The focus list is locked.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Keep my list", action: state.dismissProposal)
            }.controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(key: String, source: ActivityIcon.Source, name: String, isNew: Bool) -> some View {
        Button { state.toggleProposed(key) } label: {
            HStack {
                Image(systemName: proposal.skipped.contains(key) ? "square" : "checkmark.square.fill")
                ActivityIcon(source: source)
                Text(name).lineLimit(1)
                if isNew { Text("new").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(.callout)
    }
}
