import SwiftUI
import AirGapCore

/// Sets a commitment lock on a session, a theme or the block list. Shown in place of the tab, like Settings.
struct LockSetupView: View {
    @EnvironmentObject var state: AppState
    let scope: LockScope
    @State private var days = 1
    @State private var partner = false
    @State private var code = ""
    @State private var again = ""
    @State private var quickCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: title) { state.lockSetup = nil }
            if scope == .session {
                Text(state.phase == .idle ? "The session is locked from the moment it starts until its time is up."
                     : "Locked until the session's time is up.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("For").font(.caption.bold()).foregroundStyle(.secondary)
                Picker("", selection: $days) {
                    ForEach(CommitmentLock.lengthOptionsDays, id: \.self) { Text(Self.length($0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Text("While locked").font(.caption.bold()).foregroundStyle(.secondary)
            Text(frozen).font(.caption).foregroundStyle(.secondary)

            Text("Way out").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $partner) {
                Text("Delay").tag(false)
                Text("Partner code").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Text(partner
                 ? "Someone else types a code now and whenever you want out. AirGap keeps only a hash, so a forgotten code means waiting for the lock to end. Use a new code, not a real PIN or password."
                 : scope == .session ? "No way out: the session ends when its time is up."
                 : "Loosening a rule or unlocking takes effect 24 hours later, or when the lock ends, whichever comes first.")
                .font(.caption).foregroundStyle(.secondary)
            if partner {
                SecureField("Partner code", text: $code).textFieldStyle(.roundedBorder)
                SecureField("Again", text: $again).textFieldStyle(.roundedBorder)
            }
            if scope != .blockList {
                Toggle("Allow the \(Preferences.quickAllowMinutes)-minute quick check", isOn: $quickCheck)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { state.lockSetup = nil }.keyboardShortcut(.cancelAction)
                Button("Lock", action: lock).buttonStyle(.borderedProminent).disabled(partner && (code.isEmpty || code != again))
            }
        }
    }

    private var title: String {
        switch scope {
        case .session: return "Lock this session"
        case .blockList: return "Lock the block list"
        case .theme(let id): return "Lock \u{201C}\(state.themes.first { $0.id == id }?.name ?? "theme")\u{201D}"
        }
    }

    private var frozen: String {
        switch scope {
        case .session: return "No pausing or ending early. Nothing is added to the focus list. Quit is hidden and AirGap comes back if it is closed."
        case .theme: return "The theme can't be edited or deleted and nothing is added to its list. Its runs can't be paused or ended early. Quit is hidden and AirGap comes back if it is closed."
        case .blockList: return "No rule can be removed. Adding rules still works. Quit is hidden and AirGap comes back if it is closed."
        }
    }

    private func lock() {
        let override: LockOverride = partner ? .partner(PartnerCode.make(code)) : .delay
        state.lock(scope, days: scope == .session ? nil : days, override: override, allowsQuickCheck: quickCheck)
        code = ""; again = ""
        state.lockSetup = nil
    }

    static func length(_ days: Int) -> String {
        switch days {
        case 1: return "1 day"
        case 7: return "1 week"
        default: return "\(days) days"
        }
    }
}

/// Asks the partner for the code that applies a loosening change.
struct CodePromptView: View {
    @EnvironmentObject var state: AppState
    let prompt: CodePrompt
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Partner code", back: state.dismissCodePrompt)
            Text(what).font(.callout).foregroundStyle(.secondary)
            SecureField("Code", text: $code).textFieldStyle(.roundedBorder).onSubmit(confirm)
            if state.codeFailed { Text("Wrong code.").font(.caption).foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: state.dismissCodePrompt).keyboardShortcut(.cancelAction)
                Button(label, action: confirm).buttonStyle(.borderedProminent).disabled(code.isEmpty)
            }
        }
    }

    private var what: String {
        switch prompt.change {
        case .unlock: return "Your partner's code ends the lock now."
        case .removeRule(let id): return "Your partner's code removes \(state.rules.first { $0.id == id }?.displayName ?? "the rule") from the block list."
        case .addSite(let host): return "Your partner's code adds \(host) to the locked focus list."
        case .addApp(let app): return "Your partner's code adds \(app.name) to the locked focus list."
        }
    }

    private var label: String { if case .unlock = prompt.change { return "Unlock" } else { return "Apply" } }

    private func confirm() { state.confirmCode(code); code = "" }
}

/// One quiet line: a Lock control, or the lock's status with its way out.
struct LockStatusLine: View {
    @EnvironmentObject var state: AppState
    let scope: LockScope

    var body: some View {
        Group {
            if let lock = current {
                locked(lock)
            } else if scope == .session, let setup = state.draft.lock, state.phase == .idle {
                HStack(spacing: 6) {
                    Label("Locks when it starts · \(Self.wayOut(setup.override))", systemImage: "lock.fill")
                    Spacer()
                    Button("Remove", action: state.removeDraftLock).buttonStyle(.link)
                }
            } else if scope != .session || state.phase != .paused {
                Button { state.lockSetup = scope } label: { Label("Lock", systemImage: "lock") }.buttonStyle(.link)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var current: CommitmentLock? {
        switch scope {
        case .session: return state.sessionLock
        case .blockList: return state.blockListLock
        case .theme(let id): return state.themeLock(id)
        }
    }

    @ViewBuilder private func locked(_ lock: CommitmentLock) -> some View {
        HStack(spacing: 6) {
            if lock.scope == .session, lock.isDelay {
                Label("Locked until the session ends", systemImage: "lock.fill")
            } else if let pending = lock.pending(.unlock) {
                Label("Unlocks \(Self.date(pending.effectiveAt))", systemImage: "lock.open")
                Spacer()
                Button("Keep locked") { state.cancelPending(pending.id, on: lock.id) }.buttonStyle(.link)
            } else {
                Label("Locked until \(Self.date(lock.endsAt)) · \(Self.wayOut(lock.override))", systemImage: "lock.fill")
                Spacer()
                Button("Unlock…") { state.requestChange(.unlock, on: lock) }.buttonStyle(.link)
            }
        }
        .lineLimit(1)
    }

    static func wayOut(_ override: LockOverride) -> String { if case .delay = override { return "Delay" } else { return "Partner code" } }

    static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
    }
}

/// A queued change on a locked list, with a way to take it back.
struct PendingNote: View {
    @EnvironmentObject var state: AppState
    let change: PendingChange
    let lockID: UUID

    var body: some View {
        HStack(spacing: 4) {
            Text("\(verb) \(LockStatusLine.date(change.effectiveAt))")
            Button("Keep") { state.cancelPending(change.id, on: lockID) }.buttonStyle(.link)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var verb: String {
        switch change.kind {
        case .removeRule: return "Removes"
        case .addSite, .addApp: return "Adds"
        case .unlock: return "Unlocks"
        }
    }
}
