import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import AirGapCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    let close: () -> Void
    @State private var confirmDelete = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var exportError: String?
    @AppStorage(Preferences.Key.idleMinutes) private var idleMinutes = Preferences.defaultIdleMinutes
    @AppStorage(Preferences.Key.quickAllowMinutes) private var quickAllowMinutes = Preferences.defaultQuickAllowMinutes
    @AppStorage(Preferences.Key.claudeModel) private var claudeModel = Preferences.defaultClaudeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Settings", back: close)
            // Scrolls so an open Categories list can't push the Back button off the fixed-height window.
            ScrollView { settings.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .alert("Delete all AirGap data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((state.lockDescriptions.isEmpty ? "" : state.lockDescriptions.joined(separator: " ") + " Deleting all data also removes the lock. ")
                 + "Screen time, open counts, categories, block rules, focus lists and session history will be removed. This cannot be undone.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $state.agent) {
                ForEach(CoachAgent.allCases, id: \.self) { Text($0.name).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(agentNote).font(.caption).foregroundStyle(.secondary)
            if state.agent == .claude, state.coachEnabled {
                Picker("Model", selection: $claudeModel) {
                    ForEach(Preferences.claudeModels, id: \.self) { Text($0.capitalized).tag($0) }
                }.fixedSize()
            }

            Text("General").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
            Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Picker("Stop counting after idle", selection: $idleMinutes) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            }.fixedSize()
            Picker("Quick allow during focus", selection: $quickAllowMinutes) {
                ForEach([2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            }.fixedSize()
            Text("How long a blocked app or site can be let through, once per session. With an assistant, blocked pages ask for a reason instead.")
                .font(.caption).foregroundStyle(.secondary)
            CategorySettings().padding(.top, 4)
            Button("Export screen time…", action: exportUsage).buttonStyle(.link).font(.caption).padding(.top, 8)
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
            Button("Delete all data…") { confirmDelete = true }.buttonStyle(.link).font(.caption)
        }
    }

    /// Saves every day's screen time as a CSV wherever the user picks.
    private func exportUsage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "AirGap screen time \(UsageLog.dayKey(Date())).csv"
        // A menu-bar app isn't frontmost, so the panel would open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UsageExport.csv(state.usage, categorization: state.categorization).write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var agentNote: String {
        switch state.agent {
        case .none: "No planning, reflection or page passes: blocked pages stay blocked. AirGap never calls an assistant."
        case .claude where !state.coachEnabled: "Claude Code isn't installed, so planning, reflection and page passes stay off."
        case .claude: "Claude plans and reflects on sessions, and decides whether a blocked page can open for the reason you give. Uses your installed Claude Code."
        case .codex where !state.coachEnabled: "Codex isn't installed, so planning, reflection and page passes stay off."
        case .codex: "Codex plans and reflects on sessions, and decides whether a blocked page can open for the reason you give. Uses your installed Codex CLI and its default model."
        }
    }
}

// MARK: Categories

/// Fixed colors for categories, picked by `UsageCategory.colorIndex`.
enum CategoryPalette {
    static let colors: [Color] = [.blue, .orange, .cyan, .green, .purple, .pink, .red, .gray, .yellow, .mint]
    static func color(_ category: UsageCategory) -> Color { colors[category.colorIndex % colors.count] }
}

/// Rename, add and delete categories. Collapsed so Settings stays short.
private struct CategorySettings: View {
    @EnvironmentObject var state: AppState
    @State private var newName = ""

    var body: some View {
        DisclosureGroup("Categories") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.categorization.categories) { category in
                    HStack {
                        Circle().fill(CategoryPalette.color(category)).frame(width: 8, height: 8)
                        CategoryNameField(category: category)
                        if category.id != Categorization.otherID {
                            Button { state.deleteCategory(category.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete. Its items move to their next best category.")
                        }
                    }
                }
                HStack {
                    TextField("New category", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func add() { state.addCategory(named: newName); newName = "" }
}

private struct CategoryNameField: View {
    @EnvironmentObject var state: AppState
    let category: UsageCategory
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name).textFieldStyle(.plain)
            .onAppear { name = category.name }
            .onChange(of: category.name) { name = category.name }
            .onSubmit { state.renameCategory(category.id, to: name); name = category.name }
    }
}
