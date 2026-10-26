// `--tour <folder>`: Elxplorer uses itself, step by step at a watchable pace, for the screen recording App Review
// asks new developers for: previews, a multiple selection, a 3D model, folders and search, in a folder of
// made-up files, on a plain backdrop. It doesn't save its tabs on the way out, so yours come back as they were.

import AppKit

@MainActor
enum Tour {
    /// The display with the menu bar: the one the recording is made of (not "the main screen", which is
    /// whichever screen the active window happens to be on).
    static var screen: NSScreen { NSScreen.screens.first! }

    static var active = false
    private static var backdrop: NSWindow?

    static func run(_ folder: URL) {
        active = true
        stage()
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let browser = app.newWindow(folder)
        if let window = browser.window, let screen = Optional(Tour.screen) {
            let size = NSSize(width: min(1400, screen.visibleFrame.width - 120), height: min(860, screen.visibleFrame.height - 80))
            window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        Task {
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func pick(_ names: [String], in dir: URL) {
                for (n, name) in names.enumerated() {
                    let chosen = Set((n == 0 ? [] : browser.list.selectedItems.map(\.url)) + [dir.appendingPathComponent(name)])
                    browser.list.select(chosen)
                    browser.selectionChanged()
                }
            }
            await pause(2)
            pick(["Forest.jpg"], in: folder); await pause(2.5)
            pick(["Desert.jpg", "Lake.jpg", "Forest.jpg"], in: folder); await pause(3)
            pick(["Cube.stl"], in: folder); await pause(3)
            let holiday = folder.appendingPathComponent("Holiday")
            browser.navigate(to: holiday); await pause(1.8)
            pick(["Sunset.jpg"], in: holiday); await pause(2.2)
            browser.navigate(to: folder); await pause(1.5)
            browser.searchField.stringValue = "*.jpg"
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.searchField))
            await pause(3.5)
            browser.searchField.stringValue = ""
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.searchField))
            let documents = folder.appendingPathComponent("Documents")
            browser.navigate(to: documents); await pause(1.8)
            pick(["Application form.pdf"], in: documents); await pause(3)
            NSApp.terminate(nil)
        }
    }

    /// A plain dark backdrop over the main screen, behind Elxplorer's window.
    private static func stage() {
        let screen = Tour.screen
        let w = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.level = .normal
        w.orderFrontRegardless()
        backdrop = w
    }
}
