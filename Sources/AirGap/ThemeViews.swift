import AppKit
import SwiftUI
import AirGapCore

/// Saved themes as chips above the intention field. Tapping one sets the session up; tapping it again goes back to a one-off session.
struct ThemeChipsRow: View {
    @EnvironmentObject var state: AppState
    @Binding var notebook: FocusTheme?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.themes) { theme in
                    let selected = state.draft.themeID == theme.id
                    let locked = state.isThemeLocked(theme.id)
                    Button { state.selectTheme(selected ? nil : theme.id) } label: {
                        HStack(spacing: 4) {
                            Label(theme.name, systemImage: theme.kind == .reading ? "book" : "checklist").lineLimit(1)
                            if locked { Image(systemName: "lock.fill").font(.caption2) }
                        }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…") { ThemeEditorWindow.shared.open(ThemeEdit(theme), state: state) }.disabled(locked)
                        if !locked { Button("Lock…") { state.lockSetup = .theme(theme.id) } }
                        Button("History") { notebook = theme }
                        Button("Delete", role: .destructive) { state.deleteTheme(theme.id) }
                            .disabled(state.session?.themeID == theme.id || locked)
                    }
                }
                Button { ThemeEditorWindow.shared.open(ThemeEdit(state.newTheme()), state: state) } label: {
                    Label("New theme", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.separator))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 1)
        }
    }
}

/// What happened in the theme's last runs, led by the note the user left for this one.
struct LastTimePanel: View {
    @EnvironmentObject var state: AppState
    let theme: FocusTheme
    @Binding var notebook: FocusTheme?

    var body: some View {
        let runs = ThemeHistory.runs(of: theme.id, in: state.history)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last time").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !runs.isEmpty { Button("History") { notebook = theme }.buttonStyle(.link).font(.caption) }
            }
            if let note = ThemeHistory.lastNextTime(of: theme.id, in: state.history) {
                Label(note, systemImage: "note.text").font(.callout)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            if runs.isEmpty {
                Text("First run of this theme").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(runs.prefix(3)) { run in RunLine(run: run) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One past run in a single line: outcome, date, length, note.
struct RunLine: View {
    let run: FocusSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            OutcomeIcon(outcome: run.outcome)
            Text(run.startedAt, format: .dateTime.weekday(.abbreviated).day().month()).foregroundStyle(.secondary)
            Text(Formatting.duration(run.duration ?? 0)).monospacedDigit().foregroundStyle(.secondary)
            if let note = run.note, !note.isEmpty { Text(note).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}

/// Shows the theme editor in its own window. Text fields in a sheet on the menu bar popover can't take typing,
/// because the popover never becomes the key window.
@MainActor
final class ThemeEditorWindow: NSObject, NSWindowDelegate {
    static let shared = ThemeEditorWindow()
    private var window: NSWindow?
    private weak var state: AppState?

    func open(_ edit: ThemeEdit, state: AppState) {
        self.state = state
        state.themeEdit = edit
        let window = self.window ?? makeWindow(state)
        window.title = state.themes.contains { $0.id == edit.id } ? "Edit theme" : "New theme"
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { state?.themeEdit = nil }

    private func makeWindow(_ state: AppState) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ThemeEditorSheet().environmentObject(state))
        self.window = window
        return window
    }
}

/// A theme being created or edited. Kept in `AppState` so it survives the popover closing, e.g. while choosing an app.
struct ThemeEdit: Identifiable, Equatable {
    var theme: FocusTheme
    /// Checklist rows with stable ids, so removing one while it is being typed in can't crash.
    var steps: [FocusStep]
    var newStep = ""
    var newSite = ""
    var id: UUID { theme.id }

    init(_ theme: FocusTheme) {
        self.theme = theme
        self.steps = theme.checklist.map { FocusStep(text: $0) }
    }

    /// The theme with every row and anything still typed in the add fields.
    var result: FocusTheme {
        var t = theme
        t.checklist = (steps.map(\.text) + [newStep]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let host = URLNormalizer.host(from: newSite), !t.sites.contains(host) { t.sites.append(host) }
        return t
    }
}

/// Creates or edits a theme: name, kind, length, intention, checklist and its own focus list.
struct ThemeEditorSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.themeEdit != nil { form(edit) }
    }

    private var edit: Binding<ThemeEdit> {
        Binding(get: { state.themeEdit ?? ThemeEdit(state.newTheme()) }, set: { state.themeEdit = $0 })
    }

    private func form(_ edit: Binding<ThemeEdit>) -> some View {
        let theme = edit.theme
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name, like Linear triage", text: theme.name).textFieldStyle(.roundedBorder)
                    Picker("Kind", selection: theme.kind) {
                        Text("Chore").tag(ThemeKind.chore)
                        Text("Reading").tag(ThemeKind.reading)
                    }.pickerStyle(.segmented)
                    Text(theme.wrappedValue.kind == .reading
                         ? "Reading runs can't be paused and let nothing else through. They end when the time is up."
                         : "Chores work like any focus session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Length", selection: theme.minutes) {
                        ForEach(FocusTheme.lengthOptions, id: \.self) { Text(Formatting.length(minutes: $0)).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("Intention, like Clear the triage inbox", text: theme.intention, axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.roundedBorder)

                    Text("Checklist").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(edit.steps) { $step in
                        HStack {
                            TextField("Step", text: $step.text).textFieldStyle(.roundedBorder)
                            Button { edit.wrappedValue.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add a step", text: edit.newStep).textFieldStyle(.roundedBorder).onSubmit { addStep(edit) }
                        Button("Add") { addStep(edit) }
                    }

                    Text("Sites").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        TextField("linear.app", text: edit.newSite).textFieldStyle(.roundedBorder).onSubmit { addSite(edit) }
                        Button("Add") { addSite(edit) }
                    }
                    ForEach(theme.wrappedValue.sites, id: \.self) { host in
                        HStack {
                            ActivityIcon(source: .web(host)); Text(host); Spacer()
                            Button { edit.wrappedValue.theme.sites.removeAll { $0 == host } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Text("Apps").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose app…", action: chooseApp).controlSize(.small)
                    }
                    ForEach(theme.wrappedValue.apps) { app in
                        HStack {
                            ActivityIcon(source: .app(app.bundleID)); Text(app.name); Spacer()
                            Button { edit.wrappedValue.theme.apps.removeAll { $0.bundleID == app.bundleID } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack {
                Spacer()
                Button("Cancel") { ThemeEditorWindow.shared.close() }.keyboardShortcut(.cancelAction)
                // No default-action shortcut: Return in the add fields must add the row, not save the sheet.
                if state.isThemeLocked(theme.wrappedValue.id) { Text("This theme is locked.").font(.caption).foregroundStyle(.secondary) }
                Button("Save") { state.saveTheme(edit.wrappedValue.result); ThemeEditorWindow.shared.close() }
                    .buttonStyle(.borderedProminent)
                    .disabled(theme.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isThemeLocked(theme.wrappedValue.id))
            }
        }
        .padding(16)
        .frame(width: 380, height: 520)
    }

    private func addStep(_ edit: Binding<ThemeEdit>) {
        let text = edit.wrappedValue.newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { edit.wrappedValue.steps.append(FocusStep(text: text)) }
        edit.wrappedValue.newStep = ""
    }

    private func addSite(_ edit: Binding<ThemeEdit>) {
        if let host = URLNormalizer.host(from: edit.wrappedValue.newSite), !edit.wrappedValue.theme.sites.contains(host) {
            edit.wrappedValue.theme.sites.append(host)
        }
        edit.wrappedValue.newSite = ""
    }

    /// Writes straight into `AppState`, so the pick survives the popover closing while the panel is open.
    private func chooseApp() {
        guard let app = chooseApplication(), state.themeEdit?.theme.apps.contains(where: { $0.bundleID == app.bundleID }) == false else { return }
        state.themeEdit?.theme.apps.append(app)
    }
}

/// Every run of one theme, newest first, with how long runs take lately.
struct ThemeNotebookSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let theme: FocusTheme

    var body: some View {
        let runs = ThemeHistory.runs(of: theme.id, in: state.history)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.headline)
                Text("\(theme.kind == .reading ? "Reading" : "Chore") · \(runs.count) run\(runs.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if let trend = trendText { Text(trend).font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if runs.isEmpty { Text("No runs yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(runs) { NotebookEntry(run: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 380, height: 520)
    }

    private var trendText: String? {
        guard let trend = ThemeHistory.trend(of: theme.id, in: state.history) else { return nil }
        if theme.kind == .chore, let earlier = trend.earlierAverageSeconds {
            return "Recent runs average \(Formatting.duration(trend.recentAverageSeconds)), earlier \(Formatting.duration(earlier))"
        }
        return "Runs average \(Formatting.duration(trend.averageSeconds))"
    }
}

/// One run in the notebook: the line from Last time, then its notes and the assistant's reflection.
private struct NotebookEntry: View {
    let run: FocusSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OutcomeIcon(outcome: run.outcome)
                Text(run.startedAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                Spacer()
                Text(Formatting.duration(run.duration ?? 0)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption.bold())
            if let note = run.note, !note.isEmpty { Text(note).font(.callout) }
            if let next = run.nextTime, !next.isEmpty {
                Label(next, systemImage: "note.text").font(.caption).foregroundStyle(.secondary)
            }
            if let reflection = run.reflection {
                Text(reflection).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                    .onTapGesture { expanded.toggle() }
                    .help(expanded ? "Show less" : "Show all")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
