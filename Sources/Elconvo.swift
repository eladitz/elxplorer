// Talking to Elconvo (the converter): which formats and tools fit a selection, and asking it to act.
// Requests go over a distributed notification, which only apps on this Mac can send or receive.

import AppKit

struct ElconvoAction {
    let id: String
    let title: String
}

@MainActor
enum Elconvo {
    static let bundleID = "com.itzkin.elconvo"
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    /// Sandboxed, Elxplorer can't run Elconvo's helper or send it details over a notification; the App Store
    /// builds will talk through a folder the two share instead. Until then the Store build leaves Elconvo out.
    static var isInstalled: Bool { !Distribution.appStore && appURL != nil }

    /// Answers are the same for the same kinds of file, so they're kept per extension mix (and single vs several).
    private static var cache: [String: (convert: [ElconvoAction], tools: [ElconvoAction])] = [:]

    static func actions(for urls: [URL]) -> (convert: [ElconvoAction], tools: [ElconvoAction]) {
        guard let app = appURL, !urls.isEmpty else { return ([], []) }
        let key = Set(urls.map { $0.hasDirectoryPath ? "/" : $0.pathExtension.lowercased() }).sorted().joined(separator: ",")
            + (urls.count > 1 ? "+many" : "")
        if let hit = cache[key] { return hit }
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/Elconvo")
        p.arguments = ["--list-actions"] + urls.prefix(50).map(\.path)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ([], []) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        func list(_ key: String, _ title: String) -> [ElconvoAction] {
            (json[key] as? [[String: String]] ?? []).compactMap { d in d["id"].map { ElconvoAction(id: $0, title: d[title] ?? $0) } }
        }
        let result = (list("convert", "label"), list("tools", "title"))
        cache[key] = result
        return result
    }

    /// Sends a request, launching Elconvo first if it isn't running.
    static func send(_ info: [String: Any]) {
        let post = {
            DistributedNotificationCenter.default().postNotificationName(.init("com.itzkin.elconvo.command"), object: nil,
                                                                         userInfo: info, deliverImmediately: true)
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isFinishedLaunching) {
            post()
            return
        }
        guard let app = appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
            // Give it a moment to start listening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { post() }
        }
    }

    static func wheel(_ urls: [URL], at point: NSPoint, tools: Bool) {
        send(["action": "wheel", "files": urls.map(\.path), "x": Double(point.x), "y": Double(point.y), "tools": tools])
    }

    static func convert(_ urls: [URL], to format: String) { send(["action": "convert", "files": urls.map(\.path), "format": format]) }
    static func tool(_ urls: [URL], _ op: String) { send(["action": "tool", "files": urls.map(\.path), "op": op]) }
    static func open(_ urls: [URL]) { send(["action": "open", "files": urls.map(\.path)]) }
}
