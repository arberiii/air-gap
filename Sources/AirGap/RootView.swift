import AppKit
import SwiftUI
import AirGapCore

private enum Tab: String, CaseIterable { case time = "Screen time", block = "Block list", focus = "Focus" }

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .time
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 12) {
            if showSettings {
                SettingsView(close: { showSettings = false })
            } else if let prompt = state.codePrompt {
                CodePromptView(prompt: prompt)
            } else if let scope = state.lockSetup {
                LockSetupView(scope: scope).id(scope)
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case .time: ScreenTimeView()
                case .block: BlockListView()
                case .focus: FocusView()
                }
            }
            Divider()
            HStack {
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Settings")
                Spacer()
                if state.isLocked {
                    Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary).help("Quit comes back when the lock ends")
                } else {
                    Button("Quit AirGap") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 400, height: 580)
    }
}

/// A button that asks the assistant, with a spinner while it thinks and its last error underneath.
struct CoachButton: View {
    @EnvironmentObject var state: AppState
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) { Label(title, systemImage: "sparkles") }.disabled(disabled || state.coachBusy)
            if state.coachBusy { ProgressView().controlSize(.small); Text("Thinking…").font(.caption).foregroundStyle(.secondary) }
        }
        if let error = state.coachError { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

/// Asks for an app in /Applications. Nil when cancelled or the pick has no bundle id.
@MainActor
func chooseApplication() -> FocusApp? {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return nil }
    return FocusApp(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
}

/// The title row of a panel that replaces the tabs, with a Back button.
struct PanelHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline).lineLimit(1)
            Spacer()
        }
    }
}
