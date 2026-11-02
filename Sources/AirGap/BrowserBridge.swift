import AppKit
import AirGapCore

/// Reads and redirects the active tab of supported browsers through AppleScript.
/// The first call per browser triggers the macOS "Automation" permission prompt.
/// Scripts run one at a time on a queue of their own, so a browser that doesn't answer never stalls the main thread.
enum BrowserBridge {
    private enum Family { case safari, chromium }

    private static let browsers: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }
    static var bundleIDs: Set<String> { Set(browsers.keys) }

    private static let queue = DispatchQueue(label: "com.arberiii.airgap.applescript", qos: .userInitiated)

    static func currentURL(bundleID: String) async -> URL? { await onQueue { activeTab(bundleID, "URL") }.flatMap { URL(string: $0) } }

    static func currentTitle(bundleID: String) async -> String? {
        await onQueue { activeTab(bundleID, "title") }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The AppleScript for the active tab's `URL` or `title` in this browser, or nil for anything else.
    private static func tabProperty(_ bundleID: String, _ property: String) -> String? {
        switch browsers[bundleID] {
        case .safari: "\(property == "title" ? "name" : property) of front document"
        case .chromium: "\(property) of active tab of front window"
        case nil: nil
        }
    }

    private static func activeTab(_ bundleID: String, _ property: String) -> String? {
        tabProperty(bundleID, property).flatMap { run("tell application id \"\(bundleID)\" to return \($0)") }
    }

    /// What the block page offers under its message.
    enum Offer {
        case none
        /// A link that lets the whole site through for a few minutes. Used during focus when no assistant is set up.
        case allowMinutes(Int)
        /// A form where the user types why they need this one page, for the assistant to decide.
        case ask(agentName: String, title: String?, passesLeft: Int)
    }

    /// Replaces the active tab with the block page. During a focus session `focus` puts the user's intention on the page.
    /// `note` is a line from AirGap above the offer, like the assistant's last answer.
    /// With `overBlockPage` only a tab still showing a block page is replaced.
    static func redirect(bundleID: String, message: String, focus: (intention: String, next: String?)? = nil,
                         offer: Offer = .none, blockedURL: URL? = nil, note: String? = nil, overBlockPage: Bool = false) {
        open(blockPage(message: message, focus: focus, extra: offerHTML(offer, blockedURL: blockedURL, bundleID: bundleID, note: note)),
             bundleID: bundleID, overBlockPage: overBlockPage)
    }

    /// Whether the active tab still shows a AirGap block page, so an answer that arrives late never replaces a tab the user moved on to.
    private static func showsBlockPage(_ bundleID: String) -> Bool { activeTab(bundleID, "URL")?.hasPrefix("data:text/html") == true }

    /// The block page's form puts its fields after this in the tab's title. Browsers won't open `airgap://` from a script,
    /// and Chrome won't change a `data:` page's fragment, but a title can always change.
    static let askMarker = "airgap-ask&"

    /// The fields the block page's form left in the active tab's title, as `url=…&browser=…&title=…&reason=…`, if any.
    static func pendingAsk(bundleID: String) async -> String? {
        guard let title = await currentTitle(bundleID: bundleID), title.hasPrefix(askMarker) else { return nil }
        return String(title.dropFirst(askMarker.count))
    }

    private static func offerHTML(_ offer: Offer, blockedURL: URL?, bundleID: String, note: String?) -> String {
        let noteHTML = note.map { "<p class=r>\(HTML.escape($0))</p>" } ?? ""
        guard let blockedURL else { return noteHTML }
        let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        switch offer {
        case .none:
            return noteHTML
        case .allowMinutes(let minutes):
            let link = "airgap://allow?url=\(encode(blockedURL.absoluteString))&browser=\(encode(bundleID))"
            return noteHTML + "<p><a href=\"\(HTML.escape(link))\">Need it for a quick check? Allow for \(minutes) minutes</a></p>"
        case .ask(let agentName, let title, let passesLeft):
            // Titles are capped in length, so keep the page title short.
            let hidden = [("url", blockedURL.absoluteString), ("browser", bundleID), ("title", String((title ?? "").prefix(120)))]
                .map { "<input type=hidden name=\($0.0) value=\"\(HTML.escape($0.1))\">" }.joined()
            return noteHTML + """
            <form onsubmit="event.preventDefault();document.title='\(askMarker)'+[...new FormData(this)]\
            .map(([k,v])=>k+'='+encodeURIComponent(v)).join('&');this.outerHTML='<p class=r>Sending…</p>'">\(hidden)\
            <textarea name=reason required minlength=\(PagePass.minReasonLength) maxlength=400 rows=3 \
            placeholder="Need this exact page? Say why, specifically."></textarea>\
            <button>Ask \(HTML.escape(agentName))</button>\
            <p class=h>Only this page opens, for \(PagePass.minutes) minutes. \(passesLeft) of \(PagePass.dailyLimit) passes left today.</p></form>
            """
        }
    }

    /// Points the active tab at `target`. With `overBlockPage` only a tab still showing a block page moves.
    static func open(_ target: URL, bundleID: String, overBlockPage: Bool = false) {
        open(target.absoluteString, bundleID: bundleID, overBlockPage: overBlockPage)
    }

    private static func open(_ target: String, bundleID: String, overBlockPage: Bool) {
        guard let expr = tabProperty(bundleID, "URL") else { return }
        let escaped = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        queue.async {
            guard !overBlockPage || showsBlockPage(bundleID) else { return }
            _ = run("tell application id \"\(bundleID)\" to set \(expr) to \"\(escaped)\"")
        }
    }

    private static func blockPage(message: String, focus: (intention: String, next: String?)?, extra: String) -> String {
        let body: String
        if let focus {
            let next = focus.next.map { "<p class=k>Next step</p><p class=n>\(HTML.escape($0))</p>" } ?? ""
            body = """
            <p class=k>You're focusing on</p><h1>\(HTML.escape(focus.intention))</h1>\(next)\
            <p class=m>Does this tab help with that? If not, close it and go back.</p>\(extra)
            """
        } else {
            body = "<h1>Blocked by AirGap</h1><p class=m>\(HTML.escape(message))</p>\(extra)"
        }
        let html = """
        <!doctype html><meta charset=utf-8><title>AirGap</title><style>\
        body{font-family:-apple-system,sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;\
        min-height:100vh;margin:0;padding:0 24px;box-sizing:border-box;background:#111;color:#eee;text-align:center}\
        h1{font-size:34px;max-width:720px;margin:4px 0 28px;line-height:1.25}.k{color:#7c7;text-transform:uppercase;\
        letter-spacing:.08em;font-size:12px;margin:0}.n{font-size:20px;max-width:620px;margin:6px 0 28px}.m{color:#999}\
        a{color:#777;font-size:13px}.r{color:#eee;font-size:15px;max-width:560px;margin:24px 0 0}\
        form{display:flex;flex-direction:column;align-items:center;gap:10px;width:100%;max-width:480px;margin-top:28px}\
        textarea{width:100%;box-sizing:border-box;background:#1c1c1c;color:#eee;border:1px solid #333;border-radius:8px;\
        padding:10px 12px;font:inherit;font-size:14px;resize:vertical}textarea:focus{outline:none;border-color:#7c7}\
        button{background:#2a2a2a;color:#eee;border:1px solid #444;border-radius:8px;padding:8px 16px;font:inherit;font-size:14px;cursor:pointer}\
        button:hover{border-color:#7c7}.h{color:#666;font-size:12px;margin:0}</style>\
        <body>\(body)</body>
        """
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    private static func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
