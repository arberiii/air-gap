import AppKit
import SwiftUI
import AirGapCore

/// Loads app icons from the system and site favicons from the web, caching both in memory and on disk.
@MainActor
final class IconStore {
    static let shared = IconStore()

    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AirGap/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func appIcon(bundleID: String) -> NSImage? {
        let key = ActivityKey.app(bundleID)
        if let hit = cache[key] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = image
        return image
    }

    func favicon(host: String) async -> NSImage? {
        let key = ActivityKey.web(host)
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }
        let file = directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            cache[key] = image
            return image
        }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")!
        components.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else {
            missing.insert(key)
            return nil
        }
        try? data.write(to: file)
        cache[key] = image
        return image
    }
}

/// Shows the real icon for an app or website, falling back to a generic symbol.
struct ActivityIcon: View {
    enum Source: Equatable {
        case app(String)
        case web(String)
    }

    let source: Source
    @State private var image: NSImage?

    init(source: Source) { self.source = source }

    /// The icon for an `ActivityKey`.
    init(key: String) {
        let id = ActivityKey.identifier(key)
        source = ActivityKey.isWeb(key) ? .web(id) : .app(id)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .task(id: source) { await load() }
    }

    private var fallback: String {
        if case .web = source { return "globe" }
        return "app"
    }

    private func load() async {
        switch source {
        case .app(let id): image = IconStore.shared.appIcon(bundleID: id)
        case .web(let host): image = await IconStore.shared.favicon(host: host)
        }
    }
}

