import AppKit
import SwiftUI
import AirGapCore

/// Shows a small floating card when AirGap hides an app, so a blocked app doesn't look like it failed to open.
/// The panel never activates AirGap, so the keyboard stays with whatever the user was using.
@MainActor
final class BlockNoticePresenter {
    private static let visibleFor: Duration = .seconds(8)

    private let model = BlockNoticeModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    var onAllow: (AppBlockNotice) -> Void = { _ in }
    var onAllowBriefly: (AppBlockNotice) -> Void = { _ in }
    /// The user typed why they need the app. Answer with `showAnswer`.
    var onAsk: (AppBlockNotice, String) -> Void = { _, _ in }

    func show(_ notice: AppBlockNotice) {
        let panel = panel ?? makePanel()
        // Don't replace a card the user is typing a reason into or waiting on.
        if panel.isVisible, model.ask != .idle { return }
        if panel.isVisible, model.notice?.bundleID == notice.bundleID {
            // Clicked the same app again: keep one card and nudge it instead of stacking new ones.
            model.notice = notice
            model.shakes += 1
        } else {
            model.notice = notice
            resize(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        scheduleDismiss()
    }

    /// The assistant's answer to an ask from the card. A yes closes the card shortly after; a no lets the user try again.
    func showAnswer(approved: Bool, reply: String) {
        guard model.ask == .asking else { return }
        model.ask = .answered(approved: approved, reply: reply)
        resize()
        if approved {
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self?.dismiss() }
            }
        } else {
            panel?.makeKey()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil); self.model.notice = nil; self.model.ask = .idle; self.model.reason = "" }
        }
    }

    private func resize() { if let panel { resize(panel) } }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BlockNoticeView(model: model, actions: .init(
            dismiss: { [weak self] in self?.dismiss() },
            allow: { [weak self] in
                guard let self, let notice = self.model.notice else { return }
                self.dismiss(); self.onAllow(notice)
            },
            allowBriefly: { [weak self] in
                guard let self, let notice = self.model.notice else { return }
                self.dismiss(); self.onAllowBriefly(notice)
            },
            openAirGap: { [weak self] in self?.dismiss(); StatusItem.open() },
            startAsk: { [weak self] in
                guard let self else { return }
                // Typing needs the card as the key window. The panel doesn't activate AirGap, so the hidden app's space stays put.
                self.dismissTask?.cancel()
                self.model.ask = .typing
                self.resize()
                self.panel?.makeKey()
            },
            sendAsk: { [weak self] in
                guard let self, let notice = self.model.notice else { return }
                let reason = self.model.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard reason.count >= PagePass.minReasonLength else { return }
                self.model.ask = .asking
                self.resize()
                self.onAsk(notice, reason)
            })))
        self.panel = panel
        return panel
    }

    /// Fits the card to its content and centers it a little above the middle of the screen the mouse is on.
    private func resize(_ panel: NSPanel) {
        guard let view = panel.contentView else { return }
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.12,
                              width: size.width, height: size.height), display: true)
    }
}

/// A borderless panel can't become key by default, which a text field needs.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class BlockNoticeModel: ObservableObject {
    enum Ask: Equatable { case idle, typing, asking, answered(approved: Bool, reply: String) }

    @Published var notice: AppBlockNotice?
    @Published var shakes = 0
    @Published var ask = Ask.idle
    @Published var reason = ""
}

private struct BlockNoticeView: View {
    struct Actions {
        let dismiss: () -> Void; let allow: () -> Void; let allowBriefly: () -> Void; let openAirGap: () -> Void
        let startAsk: () -> Void; let sendAsk: () -> Void
    }

    @ObservedObject var model: BlockNoticeModel
    let actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            if let notice = model.notice {
                if let icon = IconStore.shared.appIcon(bundleID: notice.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).saturation(0.2).opacity(0.85)
                        .overlay(alignment: .bottomTrailing) {
                            Group {
                                if notice.isFocus { Image(systemName: "moon.circle.fill").foregroundStyle(.white, .indigo) }
                                else { Image(systemName: "nosign").foregroundStyle(.red) }
                            }
                            .font(.system(size: 18, weight: .semibold))
                                .background(Circle().fill(.background)).offset(x: 4, y: 4)
                        }
                        .padding(.bottom, 4)
                }
                Text(notice.title).font(.headline).multilineTextAlignment(.center)
                Text(notice.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if case .focus(let intention, _, _) = notice.kind {
                    Text(intention).font(.body.weight(.medium)).multilineTextAlignment(.center).lineLimit(3)
                }
                if let detail = notice.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                }
                if model.ask == .idle {
                    buttons(for: notice).padding(.top, 8)
                    if let agent = notice.askAgentName {
                        Button("Need it? Ask \(agent)", action: actions.startAsk).buttonStyle(.link).font(.caption)
                            .help("Say why you need \(notice.appName). If \(agent) agrees, it opens for \(PagePass.minutes) minutes.")
                    }
                } else {
                    askView(for: notice).padding(.top, 8)
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
        .modifier(Shake(animatableData: CGFloat(model.shakes)))
        .animation(.linear(duration: 0.4), value: model.shakes)
    }

    @ViewBuilder
    private func buttons(for notice: AppBlockNotice) -> some View {
        if case .focus = notice.kind {
            VStack(spacing: 8) {
                HStack {
                    Button("Back to work", action: actions.dismiss).keyboardShortcut(.defaultAction)
                    if notice.canAllowBriefly {
                        Button("Allow \(Preferences.quickAllowMinutes) min", action: actions.allowBriefly)
                            .help("Open \(notice.appName) for a quick check. It's hidden again after \(Preferences.quickAllowMinutes) minutes. Once per session.")
                    }
                }.controlSize(.large)
                if !notice.canAddToList && !notice.canAllowBriefly {
                    Text("This is a reading session. It ends when the time is up.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if !notice.canAllowBriefly {
                    Text("You already used your quick check for \(notice.appName) this session.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if notice.canAddToList {
                    Button("Add to focus list", action: actions.allow).buttonStyle(.link).font(.caption)
                        .help("Allow \(notice.appName) for the rest of this session and future ones")
                }
            }
        } else {
            otherButtons(for: notice)
        }
    }

    @ViewBuilder
    private func askView(for notice: AppBlockNotice) -> some View {
        let agent = notice.askAgentName ?? "the assistant"
        VStack(spacing: 8) {
            switch model.ask {
            case .asking:
                ProgressView().controlSize(.small)
                Text("Asking \(agent)…").font(.caption).foregroundStyle(.secondary)
            case .answered(true, let reply):
                Text(reply).font(.callout).multilineTextAlignment(.center)
                Text("\(notice.appName) is open for \(PagePass.minutes) minutes.").font(.caption).foregroundStyle(.secondary)
            default:
                if case .answered(false, let reply) = model.ask {
                    Text(reply).font(.callout).multilineTextAlignment(.center)
                }
                TextField("Why do you need \(notice.appName)? Be specific.", text: $model.reason, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).onSubmit(actions.sendAsk)
                HStack {
                    Button("Never mind", action: actions.dismiss)
                    Button("Ask \(agent)", action: actions.sendAsk).keyboardShortcut(.defaultAction)
                        .disabled(model.reason.trimmingCharacters(in: .whitespacesAndNewlines).count < PagePass.minReasonLength)
                }.controlSize(.large)
                Text("\(notice.passesLeft) of \(PagePass.dailyLimit) passes left today.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func otherButtons(for notice: AppBlockNotice) -> some View {
        HStack {
            switch notice.kind {
            case .focus:
                EmptyView()
            case .blockList:
                Button("Got it", action: actions.dismiss).keyboardShortcut(.defaultAction)
                Button("Open AirGap", action: actions.openAirGap)
            case .limitReached:
                Button("Got it", action: actions.dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

/// A short side-to-side shake, played each time `animatableData` goes up by one.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Opens the menu bar window. SwiftUI's MenuBarExtra has no API for this, so it clicks the status item's button.
enum StatusItem {
    @MainActor static func open() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) { button.performClick(nil); return }
        }
    }

    @MainActor private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews { if let found = findButton(in: sub) { return found } }
        return nil
    }
}
