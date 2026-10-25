// The app: menus and shortcuts, windows and tabs, session restore, and becoming the default folder viewer.

import AppKit

/// Built for the Mac App Store (`./build.sh appstore`): sandboxed, and the Store does the updating.
enum Distribution {
    #if APPSTORE
    static let appStore = true
    #else
    static let appStore = false
    #endif
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let bundleID = "com.itzkin.elxplorer"
    private var launchedWithFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenus()
        // Development aid: `--snapshot out.png [folder] [search text]` draws one window to an image and quits;
        // `--snapshot-drive out.png /Volumes/X` does the same for a drive's More Info window.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-drive"), i + 2 < args.count {
            DriveWindow.show(URL(fileURLWithPath: args[i + 2]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let frame = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let folder = i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : Home.url
            let browser = newWindow(folder)
            if i + 3 < args.count { browser.searchField.stringValue = args[i + 3]; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.searchField)) }
            // ELX_SELECT="a.jpg,b.jpg": select these (in this order) before drawing.
            if let names = ProcessInfo.processInfo.environment["ELX_SELECT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    for name in names.split(separator: ",") {
                        browser.list.select(Set(browser.list.selectedItems.map(\.url) + [folder.appendingPathComponent(String(name))]))
                        browser.selectionChanged()
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if ProcessInfo.processInfo.environment["ELX_DEBUG"] != nil, let split = browser.window?.contentView?.subviews.compactMap({ $0 as? NSSplitView }).first {
                    print("split", split.bounds.width, split.subviews.map { "\($0.isHidden ? "hidden " : "")\(Int($0.frame.minX))+\(Int($0.frame.width))" })
                }
                if let frame = browser.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                exit(0)
            }
            return
        }
        Donation.usageLine = { "You've used it on \($0) different days so far." }
        Donation.start()
        #if APPSTORE
        DiskAccess.restore()
        if DiskAccess.needed { DiskAccess.ask(first: true) }
        #else
        Updater.start()   // the App Store does the updating there
        #endif
        guard !launchedWithFiles else { return }
        // Bring back the tabs from last time; otherwise start at home.
        let session = Settings.shared.lastSession.filter { FileManager.default.fileExists(atPath: $0.path) }
        let first = newWindow(session.first ?? Home.url)
        for url in session.dropFirst() { openTab(url, beside: first, focus: false) }
        first.window?.makeKeyAndOrderFront(nil)
        if !Distribution.appStore { FullDiskAccess.offerIfNeeded() }
    }

    // A "use" is a day Elxplorer was in front.
    func applicationDidBecomeActive(_ notification: Notification) { Donation.recordDay() }

    func applicationWillTerminate(_ notification: Notification) {
        // Tabs in on-screen order, so they come back the same way.
        let windows = NSApp.orderedWindows.compactMap { $0.windowController as? Browser }
        var seen = Set<ObjectIdentifier>()
        var ordered: [URL] = []
        for browser in windows {
            for tab in browser.window?.tabbedWindows ?? [browser.window].compactMap({ $0 }) {
                guard let b = tab.windowController as? Browser, seen.insert(ObjectIdentifier(b)).inserted, let url = b.folder else { continue }
                ordered.append(url)
            }
        }
        Settings.shared.lastSession = ordered
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newWindow(Home.url).window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Folders opened from the Dock, other apps or "Show in Finder" (when Elxplorer is the default viewer).
    /// A file means "show me this file": its folder opens with it selected.
    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithFiles = true
        if NSApp.windows.isEmpty { buildMenus() }
        for url in urls { reveal(url) }
    }

    /// Reuses a tab already showing that folder instead of piling up new ones.
    func reveal(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        if let existing = Browser.all.first(where: { $0.folder?.canonicalPath == folder.canonicalPath }) {
            existing.window?.makeKeyAndOrderFront(nil)
            if !isDir.boolValue { existing.navigate(to: url, record: false) }
        } else if let current = activeBrowser {
            openTab(url, beside: current)
        } else {
            newWindow(url).window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var activeBrowser: Browser? {
        (NSApp.keyWindow?.windowController as? Browser) ?? (NSApp.mainWindow?.windowController as? Browser) ?? Browser.all.last
    }

    @discardableResult
    func newWindow(_ url: URL) -> Browser {
        let browser = Browser(url: url)
        browser.window?.tabbingMode = .disallowed   // a real new window, not a tab of the frontmost one
        browser.placeOnPointerScreen()
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.tabbingMode = .preferred
        return browser
    }

    func openTab(_ url: URL, beside: Browser, focus: Bool = true) {
        let browser = Browser(url: url)
        guard let window = browser.window, let host = beside.window else { return }
        host.addTabbedWindow(window, ordered: .above)
        if focus { window.makeKeyAndOrderFront(nil) }
    }

    // MARK: Menu actions handled at app level

    @objc func newWindowAction(_ sender: Any?) {
        newWindow(activeBrowser?.folder ?? Home.url)
    }

    @objc func newTabAction(_ sender: Any?) {
        let url = activeBrowser?.folder ?? Home.url
        if let current = activeBrowser { openTab(url, beside: current) } else { newWindow(url) }
    }

    @objc func goToFolder(_ sender: Any?) {
        if let b = activeBrowser { b.window?.makeKeyAndOrderFront(nil); b.editAddress(nil) }
    }

    /// Other apps' "Show in Finder" comes here. macOS keeps plain "open this folder" with Finder: it refuses
    /// (paramErr) to change the handler for public.folder, so there's no point asking for it.
    @objc func makeDefault(_ sender: Any?) {
        runDefaults(["write", "-g", "NSFileViewer", "-string", Self.bundleID])
        let alert = NSAlert()
        alert.messageText = "Elxplorer is now your default file browser"
        alert.informativeText = "“Show in Finder” in other apps (like Chrome's “Show in Finder” for a download) now opens Elxplorer. Apps that are already running pick this up after they restart. macOS doesn't let any app replace Finder for plainly opening a folder, so those, the desktop and the Trash stay with Finder. Undo it any time from the Elxplorer menu."
        alert.runModal()
    }

    /// A menu entry that isn't there in this build (nil already means a separator in `menu`).
    static let leftOut = -99
    static var omitted: NSMenuItem { let i = NSMenuItem(); i.tag = leftOut; return i }

    @objc func website(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://ai.itzkin.com/elxplorer.html")!) }
    @objc func grantAccess(_ sender: Any?) {
        if Distribution.appStore { DiskAccess.ask(URL(fileURLWithPath: "/Volumes")) } else { FullDiskAccess.ask(fromMenu: true) }
    }
    @objc func donate(_ sender: Any?) { NSWorkspace.shared.open(Donation.page) }
    @objc func checkForUpdates(_ sender: Any?) { Task { await Updater.check(manual: true) } }

    @objc func restoreFinder(_ sender: Any?) {
        runDefaults(["delete", "-g", "NSFileViewer"])
        let alert = NSAlert()
        alert.messageText = "Finder is the default again"
        alert.runModal()
    }

    private func runDefaults(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Menus (every shortcut can be changed in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts)

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem?]) -> NSMenu {
            let m = NSMenu(title: title)
            for item in items where item?.tag != Self.leftOut { m.addItem(item ?? .separator()) }
            let holder = NSMenuItem()
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.representedObject = tag
            return i
        }
        let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let backspace = "\u{8}"

        _ = menu("Elxplorer", [
            item("About Elxplorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            nil,
            // Sandboxed apps can't change which app reveals files, nor check GitHub for updates.
            Distribution.appStore ? Self.omitted : item("Make Elxplorer the Default File Browser", #selector(makeDefault(_:)), target: self),
            Distribution.appStore ? Self.omitted : item("Restore Finder as Default", #selector(restoreFinder(_:)), target: self),
            Distribution.appStore ? Self.omitted : NSMenuItem.separator(),
            item("Elxplorer Website", #selector(website(_:)), target: self),
            Distribution.appStore ? Self.omitted : item("Check for Updates…", #selector(checkForUpdates(_:)), target: self),
            item("Support Elxplorer on Ko-fi…", #selector(donate(_:)), target: self),
            item(Distribution.appStore ? "Allow Access to Another Drive…" : "Grant Full Disk Access…", #selector(grantAccess(_:)), target: self),
            nil,
            item("Hide Elxplorer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            nil,
            item("Quit Elxplorer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = menu("File", [
            item("New Window", #selector(newWindowAction(_:)), "n", target: self),
            item("New Tab", #selector(newTabAction(_:)), "t", target: self),
            item("New Folder", #selector(Browser.newFolder(_:)), "n", [.command, .shift]),
            item("New Text Document", #selector(Browser.newTextDocument(_:)), "n", [.command, .option]),
            nil,
            item("Open", #selector(Browser.openSelection(_:)), down),
            item("Open in New Tab", #selector(Browser.openInNewTab(_:)), ""),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
            nil,
            item("Rename", #selector(Browser.renameSelection(_:)), f2, []),
            item("Move to Trash", #selector(Browser.moveToTrash(_:)), backspace),
            item("Delete Permanently…", #selector(Browser.deletePermanently(_:)), backspace, [.command, .option]),
            nil,
            item("Compress to ZIP", #selector(Browser.compress(_:)), ""),
            item("Open in Terminal", #selector(Browser.openTerminal(_:)), "t", [.command, .option]),
            item("Pin to Quick access", #selector(Browser.pinFolder(_:)), "p", [.command, .control]),
            item("Show in Finder", #selector(Browser.showInFinder(_:)), "r", [.command, .option]),
            nil,
            item("Properties", #selector(Browser.showProperties(_:)), "i"),
        ])
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            nil,
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Copy as Path", #selector(Browser.copyPath(_:)), "c", [.command, .option]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            nil,
            item("Search", #selector(Browser.find(_:)), "f"),
        ])
        let groupMenu = NSMenu(title: "Group by")
        groupMenu.addItem(item("None", #selector(Browser.groupNone(_:))))
        groupMenu.addItem(item("Type", #selector(Browser.groupByType(_:))))
        groupMenu.addItem(item("Date modified", #selector(Browser.groupByDate(_:))))
        let group = item("Group by", nil)
        group.submenu = groupMenu
        let sortMenu = NSMenu(title: "Sort by")
        for c in FileList.columns where c.id != "tags" { sortMenu.addItem(item(c.title, #selector(Browser.sortBy(_:)), tag: c.id)) }
        let sort = item("Sort by", nil)
        sort.submenu = sortMenu
        _ = menu("View", [
            item("Details", #selector(Browser.showDetails(_:)), "1"),
            item("Large Icons", #selector(Browser.showIcons(_:)), "2"),
            nil,
            sort, group,
            item("Folders First", #selector(Browser.toggleFoldersFirst(_:))),
            item("Folder Sizes", #selector(Browser.toggleFolderSizes(_:))),
            nil,
            item("Preview Pane", #selector(Browser.togglePreviewPane(_:)), "p", [.command, .option]),
            item("Auto Preview (pictures, video, PDF, text, 3D)", #selector(Browser.toggleAutoPreview(_:))),
            item("Menu Bar in Window", #selector(Browser.toggleMenuBar(_:))),
            item("Hidden Files", #selector(Browser.toggleHidden(_:)), ".", [.command, .shift]),
            item("File Name Extensions", #selector(Browser.toggleExtensions(_:))),
            nil,
            item("Refresh", #selector(Browser.refresh(_:)), "r"),
            nil,
            item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))),
        ])
        _ = menu("Go", [
            item("Back", #selector(Browser.goBack(_:)), "["),
            item("Forward", #selector(Browser.goForward(_:)), "]"),
            item("Up", #selector(Browser.goUp(_:)), up),
            nil,
            item("Go to Folder…", #selector(goToFolder(_:)), "l", target: self),
            item("Go to Folder…", #selector(goToFolder(_:)), "g", [.command, .shift], target: self),
            nil,
            item("Home", #selector(Browser.goHome(_:)), "h", [.command, .shift]),
            item("Desktop", #selector(Browser.goDesktop(_:)), "d", [.command, .shift]),
            item("Documents", #selector(Browser.goDocuments(_:)), "o", [.command, .shift]),
            item("Downloads", #selector(Browser.goDownloads(_:)), "l", [.command, .option]),
            item("Applications", #selector(Browser.goApplications(_:)), "a", [.command, .shift]),
        ]).items.filter { $0.keyEquivalent == "g" }.forEach { $0.isAlternate = false; $0.isHidden = true }
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            nil,
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]),
        ])
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

@main
enum Entry {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
