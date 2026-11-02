import AppKit
import SwiftUI
import AirGapCore

struct BlockListView: View {
    @EnvironmentObject var state: AppState
    @State private var input = ""
    @State private var kind: BlockKind = .site
    @State private var limit = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Block", selection: $kind) {
                ForEach(BlockKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                TextField(kind == .page ? "youtube.com/shorts" : kind == .site ? "reddit.com" : "Choose an app →", text: $input)
                    .textFieldStyle(.roundedBorder).disabled(kind == .app).onSubmit(add)
                TextField("min/day", text: $limit).textFieldStyle(.roundedBorder).frame(width: 70)
                Button(kind == .app ? "Choose…" : "Add", action: add)
            }
            if let rule = suggestion {
                Button { addSuggestion(rule) } label: {
                    HStack {
                        ActivityIcon(source: rule.iconSource)
                        Text("Block \(rule.displayName)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Add what you were just using")
            }
            if failed { Text("Could not read that address.").font(.caption).foregroundStyle(.red) }
            Text("Site blocks every subdomain. Exact page blocks only that page. A daily limit blocks only after you used it up.")
                .font(.caption).foregroundStyle(.secondary)
            LockStatusLine(scope: .blockList)
            List {
                ForEach(state.rules) { rule in
                    HStack {
                        ActivityIcon(source: rule.iconSource)
                        VStack(alignment: .leading) {
                            Text(rule.displayName).lineLimit(1)
                            Text(rule.kind.label + (rule.dailyLimitMinutes.map { " · \($0) min/day" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let lock = state.blockListLock, let pending = lock.pending(.removeRule(rule.id)) {
                            PendingNote(change: pending, lockID: lock.id)
                        } else {
                            Button { state.remove(rule) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// The app or page used just before the menu bar window opened, as a rule of the chosen kind, unless it's already blocked.
    /// A non-browser app has no page, so it's suggested as an app on every tab.
    private var suggestion: BlockRule? {
        guard let context = state.current else { return nil }
        let rule: BlockRule?
        if kind == .app || !BrowserBridge.isBrowser(context.bundleID) {
            rule = BlockRule(kind: .app, value: context.bundleID, displayName: context.appName)
        } else {
            rule = context.url.flatMap { BlockRule.web($0.absoluteString, kind: kind) }
        }
        guard let rule, !state.rules.contains(where: { $0.kind == rule.kind && $0.value == rule.value }) else { return nil }
        return rule
    }

    private func addSuggestion(_ rule: BlockRule) {
        let minutes = Int(limit)
        if rule.kind == .app {
            state.addAppRule(bundleID: rule.value, name: rule.displayName, limit: minutes)
        } else {
            failed = !state.addWebRule(rule.value, kind: rule.kind, limit: minutes)
        }
        if !failed { limit = "" }
    }

    private func add() {
        let minutes = Int(limit)
        if kind == .app { return chooseApp(minutes) }
        failed = !state.addWebRule(input, kind: kind, limit: minutes)
        if !failed { input = ""; limit = "" }
    }

    private func chooseApp(_ minutes: Int?) {
        guard let app = chooseApplication() else { return }
        state.addAppRule(bundleID: app.bundleID, name: app.name, limit: minutes)
        limit = ""
    }
}

private extension BlockRule {
    /// The app's icon, or the favicon of the site the rule's page is on.
    var iconSource: ActivityIcon.Source { kind == .app ? .app(value) : .web(String(value.prefix { $0 != "/" })) }
}
