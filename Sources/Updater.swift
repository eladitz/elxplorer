// Once a day, ask GitHub for the latest release; if it's newer than this copy, offer the download.
// The same file lives in Elconvo and Elxplorer. Installing stays manual (open the DMG, drag to Applications),
// because replacing a running app in place needs a Developer ID–signed build.

import AppKit

@MainActor
enum Updater {
    private static let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"

    private static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App" }
    private static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// The repos are named after the apps: eladitz/elconvo, eladitz/elxplorer.
    private static var latestURL: URL { URL(string: "https://api.github.com/repos/eladitz/\(appName.lowercased())/releases/latest")! }

    static func start() {
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { checkIfDue() } }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { checkIfDue() }
    }

    private static func checkIfDue() {
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check(manual: false) }
    }

    /// From the menu (`manual`), it always answers, even "you're up to date" or "couldn't check".
    static func check(manual: Bool) async {
        defaults.set(Date(), forKey: lastCheckKey)
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String
        else {
            if manual { tell("Couldn't check for updates", "GitHub didn't answer. Check your connection and try again.") }
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: current) else {
            if manual { tell("\(appName) is up to date", "You have the latest version, \(current).") }
            return
        }
        if !manual && defaults.string(forKey: skippedKey) == latest { return }
        let assets = release["assets"] as? [[String: Any]] ?? []
        let dmg = assets.lazy.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }
        let download = dmg.flatMap(URL.init(string:)) ?? URL(string: release["html_url"] as? String ?? "")!
        offer(latest, notes: release["body"] as? String ?? "", download: download)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    private static func offer(_ version: String, notes: String, download: URL) {
        guard NSEvent.pressedMouseButtons == 0 else {   // never in the middle of a drag; ask on the next pass
            defaults.removeObject(forKey: lastCheckKey)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(appName) \(version) is available"
        alert.informativeText = "You have \(current).\n\n\(notes.prefix(600))\n\nOpen the downloaded file and drag \(appName) into Applications to replace this copy."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(download)
        case .alertThirdButtonReturn: defaults.set(version, forKey: skippedKey)
        default: break
        }
    }

    private static func tell(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
