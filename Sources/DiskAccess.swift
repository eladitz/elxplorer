// The App Store build runs in Apple's sandbox, which only lets an app into places you pick. So the first
// time, Elxplorer asks you to pick the whole disk (as Commander One and ForkLift do); other drives can be
// added the same way. Each choice is kept as a security-scoped bookmark and reopened at every launch.
// Outside the Store none of this is needed (Full Disk Access covers the protected folders instead).

import AppKit

@MainActor
enum DiskAccess {
    private static let key = "diskAccessBookmarks"
    private(set) static var granted: [URL] = []

    /// Whether the build is sandboxed and still needs the disk picked.
    static var needed: Bool { Distribution.appStore && granted.isEmpty }

    /// At launch: reopen everything you allowed before.
    static func restore() {
        guard Distribution.appStore else { return }
        var fresh: [Data] = []
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            granted.append(url)
            fresh.append(stale ? (try? url.bookmarkData(options: .withSecurityScope)) ?? data : data)
        }
        UserDefaults.standard.set(fresh, forKey: key)
    }

    /// Whether a place is inside something you've allowed.
    static func covers(_ url: URL) -> Bool {
        !Distribution.appStore || granted.contains { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) }
    }

    /// Opens the picker on the disk (or a drive) with an explanation; true if you allowed it.
    @discardableResult
    static func ask(_ start: URL = URL(fileURLWithPath: "/"), first: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = "Allow Access"
        panel.message = first
            ? "Apps from the App Store can only open places you choose. Choose your disk (Macintosh HD) and click Allow Access, once, so Elxplorer can show all your files."
            : "Choose the drive or folder Elxplorer may open, and click Allow Access."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return false }
        _ = url.startAccessingSecurityScopedResource()
        granted.append(url)
        var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: key)
        return true
    }
}
