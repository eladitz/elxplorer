// Drives: their real free space, a hover summary, and the More Info window.

import AppKit

struct DriveInfo {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let purgeable: Int64   // part of `free` macOS can clear on its own (APFS caches, etc.)
    let format: String
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isReadOnly: Bool

    var used: Int64 { max(0, total - free) }
    /// SD cards in a built-in reader report "internal", but you can still pull them out.
    var connection: String { isRemovable || isEjectable ? "Removable" : isInternal ? "Internal" : "External" }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                         .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey]

    static func read(_ url: URL) -> DriveInfo {
        let v = try? url.resourceValues(forKeys: Set(keys))
        // "Free for important files" counts space macOS can purge, but only Apple-formatted drives report it;
        // ExFAT/FAT USB sticks say 0 there. Use whichever figure is real.
        let available = Int64(v?.volumeAvailableCapacity ?? 0)
        var important = v?.volumeAvailableCapacityForImportantUsage ?? 0
        var plain = available
        if important == 0 && plain == 0 {
            var s = statfs()
            if statfs(url.path, &s) == 0 { plain = Int64(s.f_bavail) * Int64(s.f_bsize) }
        }
        important = max(important, plain)
        return DriveInfo(url: url, name: v?.volumeName ?? url.lastPathComponent, total: Int64(v?.volumeTotalCapacity ?? 0),
                         free: important, purgeable: max(0, important - plain), format: v?.volumeLocalizedFormatDescription ?? "",
                         isInternal: v?.volumeIsInternal ?? true, isRemovable: v?.volumeIsRemovable ?? false,
                         isEjectable: v?.volumeIsEjectable ?? false, isReadOnly: v?.volumeIsReadOnly ?? false)
    }

    /// What hovering a drive shows.
    var summary: String {
        guard total > 0 else { return name }
        var lines = [name,
                     "Total: \(Format.size(total))",
                     "Used: \(Format.size(used)) (\(Int((usedFraction * 100).rounded()))%)",
                     "Free: \(Format.size(free))"]
        if purgeable > 1_000_000_000 { lines.append("  (\(Format.size(purgeable)) of that macOS can clear itself)") }
        lines.append([format, isReadOnly ? "Read-only" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum DriveWindow {
    private static var open: [NSWindow] = []

    static func show(_ url: URL) {
        let d = DriveInfo.read(url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(d.name) — More Info"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(labelWithString: d.name)
        title.font = .boldSystemFont(ofSize: 18)
        let kind = NSTextField(labelWithString: [d.format, "\(d.connection) drive"].filter { !$0.isEmpty }.joined(separator: " · "))
        kind.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, NSStackView(views: [title, kind])])
        (heading.views[1] as! NSStackView).orientation = .vertical
        (heading.views[1] as! NSStackView).alignment = .leading
        heading.spacing = 12

        let bar = CapacityBar(used: d.usedFraction)
        bar.heightAnchor.constraint(equalToConstant: 16).isActive = true

        func legend(_ color: NSColor?, _ label: String, _ value: String) -> NSStackView {
            var views: [NSView] = []
            if let color {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = color.cgColor
                dot.layer?.cornerRadius = 5
                dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
                views.append(dot)
            }
            let l = NSTextField(labelWithString: label)
            l.textColor = .secondaryLabelColor
            let v = NSTextField(labelWithString: value)
            v.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            views += [l, v]
            let row = NSStackView(views: views)
            row.spacing = 6
            return row
        }
        let pct = Int((d.usedFraction * 100).rounded())
        let usedColor: NSColor = d.usedFraction > 0.9 ? .systemRed : .systemBlue
        let numbers = NSStackView(views: [
            legend(usedColor, "Used", "\(Format.size(d.used))  (\(pct)%)"),
            legend(.quaternaryLabelColor, "Free", Format.size(d.free)),
            legend(nil, "Total", Format.size(d.total)),
        ])
        numbers.orientation = .vertical
        numbers.alignment = .leading
        numbers.spacing = 6

        var facts: [(String, String)] = [
            ("Format", d.format.isEmpty ? "Unknown" : d.format),
            ("Access", d.isReadOnly ? "Read-only" : "Read & write"),
            ("Connection", d.connection),
            ("Mounted at", url.path),
        ]
        if d.purgeable > 1_000_000_000 {
            facts.append(("Clearable", "\(Format.size(d.purgeable)) of the free space is caches macOS clears when it needs room"))
        }
        let factViews: [NSView] = facts.map { key, value in
            let k = NSTextField(labelWithString: key)
            k.textColor = .secondaryLabelColor
            k.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let v = NSTextField(wrappingLabelWithString: value)
            v.isSelectable = true
            v.preferredMaxLayoutWidth = 290
            let row = NSStackView(views: [k, v])
            row.alignment = .firstBaseline
            return row
        }
        let factStack = NSStackView(views: factViews)
        factStack.orientation = .vertical
        factStack.alignment = .leading
        factStack.spacing = 4

        let openButton = NSButton(title: "Open", target: nil, action: nil)
        let opener = Opener(url: url, window: window)
        openButton.target = opener
        openButton.action = #selector(Opener.openDrive)
        var buttons: [NSView] = [NSView(), openButton]
        if d.isEjectable {
            let eject = NSButton(title: "Eject", target: opener, action: #selector(Opener.eject))
            buttons.insert(eject, at: 1)
        }
        let buttonRow = NSStackView(views: buttons)
        objc_setAssociatedObject(window, "opener", opener, .OBJC_ASSOCIATION_RETAIN)

        let stack = NSStackView(views: [heading, bar, numbers, factStack, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            factStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        window.makeKeyAndOrderFront(nil)
    }

    final class Opener: NSObject {
        let url: URL
        weak var window: NSWindow?
        init(url: URL, window: NSWindow) { self.url = url; self.window = window }

        @MainActor @objc func openDrive() {
            (NSApp.delegate as? AppDelegate)?.reveal(url)
            window?.close()
        }

        @MainActor @objc func eject() {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                window?.close()
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
