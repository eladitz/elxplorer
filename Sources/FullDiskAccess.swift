// One permission instead of a prompt per folder: walks you to Full Disk Access once, then gets out of the way.

import AppKit

@MainActor
enum FullDiskAccess {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app" }
    private static var watcher: Timer?

    /// These places can only be read with Full Disk Access, and trying never shows a prompt (it just says
    /// "not permitted"). Several, because macOS versions move them around.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        for folder in ["\(home)/Library/Safari", "\(home)/Library/Mail", "\(home)/Library/Containers/com.apple.stocks"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil { return true }
        }
        return false
    }

    /// At launch: ask once (unless granted, or you said don't ask again).
    static func offerIfNeeded() {
        guard !isGranted, !UserDefaults.standard.bool(forKey: "fullDiskAccessDeclined") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ask(fromMenu: false) }
    }

    /// The menu item: explain and open Settings, whether or not you declined before.
    static func ask(fromMenu: Bool) {
        if isGranted {
            if fromMenu {
                let done = NSAlert()
                done.messageText = "\(appName) already has Full Disk Access"
                done.runModal()
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let \(appName) open all your folders?"
        alert.informativeText = """
        macOS asks separately for Desktop, Documents, Downloads, iCloud Drive, USB drives and network shares. \
        Turning on Full Disk Access once covers them all.

        In the window that opens: switch on \(appName) (or click + and choose it in Applications).
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = !fromMenu
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "fullDiskAccessDeclined") }
        guard answer == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(settingsURL)
        watchForGrant()
    }

    /// Notices when you switch it on, and offers the relaunch macOS needs for it to apply.
    private static func watchForGrant() {
        watcher?.invalidate()
        var checks = 0
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                checks += 1
                if checks > 300 { timer.invalidate(); return }   // stop after ten minutes
                guard isGranted else { return }
                timer.invalidate()
                NSApp.activate(ignoringOtherApps: true)
                let done = NSAlert()
                done.messageText = "Full Disk Access is on"
                done.informativeText = "\(appName) needs to restart once to use it."
                done.addButton(withTitle: "Relaunch \(appName)")
                done.addButton(withTitle: "Later")
                if done.runModal() == .alertFirstButtonReturn { relaunch() }
            }
        }
    }

    private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
