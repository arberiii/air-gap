import AppKit
import AirGapCore

/// A LaunchAgent that reopens AirGap whenever it is not running, loaded only while a lock is active.
enum Watchdog {
    private static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(WatchdogPlist.label).plist")
    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(WatchdogPlist.label)" }
    /// launchctl runs here, off the main thread and one sync at a time.
    private static let queue = DispatchQueue(label: "com.arberiii.airgap.watchdog", qos: .utility)

    /// Loads the agent until `until`, or unloads and removes it when nil. Decides by what launchd reports, not by the file,
    /// so a failed bootstrap or a service switched off under Login Items is retried on the next call.
    static func sync(until: Date?) { queue.async { apply(until: until) } }

    private static func apply(until: Date?) {
        let existing = try? String(contentsOf: plistURL, encoding: .utf8)
        let loaded = launchctl("print", service)
        guard let until else {
            if loaded { launchctl("bootout", service) }
            if existing != nil { try? FileManager.default.removeItem(at: plistURL) }
            return
        }
        let contents = WatchdogPlist.contents(appPath: Bundle.main.bundleURL.path,
                                              bundleID: Bundle.main.bundleIdentifier ?? "com.arberiii.airgap", until: until)
        if existing == contents, loaded { return }
        if loaded { launchctl("bootout", service) }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: plistURL, atomically: true, encoding: .utf8)
        // bootout followed at once by bootstrap can fail while launchd tears the old job down; give it a second try.
        if !launchctl("bootstrap", domain, plistURL.path) {
            Thread.sleep(forTimeInterval: 0.5)
            launchctl("bootstrap", domain, plistURL.path)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = nil; process.standardError = nil
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Refuses the app's own Quit while a lock is active. Quits with a system reason (logout, restart, shutdown) always go through.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isLocked: () -> Bool = { false }
    /// `kAEQuitReason` ('why?'), set on quit events the system sends at logout, restart and shutdown.
    private static let quitReason: AEKeyword = 0x7768_793F

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: Self.quitReason) != nil
        return Self.isLocked() && !systemQuit ? .terminateCancel : .terminateNow
    }
}
