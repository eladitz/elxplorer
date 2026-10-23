// The navigation pane: Quick access, This Mac (drives), system locations and saved searches.

import AppKit
import CoreServices

/// Finder's sidebar Favorites. The file behind them needs Full Disk Access to read, but this (old,
/// deprecated) Launch Services API hands them over without it.
enum FinderFavorites {
    static func load() -> [(name: String, url: URL)] {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue() else { return [] }
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else { return nil }
            return (LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String, url)
        }
    }
}

final class SidebarEntry: NSObject {
    enum Kind { case section, folder, volume, search(SavedSearch) }
    let title: String
    let icon: NSImage?
    let url: URL?
    let kind: Kind
    var children: [SidebarEntry] = []
    var subtitle: String?
    var usedFraction: Double?
    var tooltip: String?
    var pinned = false

    init(_ title: String, icon: NSImage? = nil, url: URL? = nil, kind: Kind) {
        self.title = title
        self.icon = icon
        self.url = url
        self.kind = kind
    }

    var isSection: Bool { if case .section = kind { return true }; return false }
}

@MainActor
protocol SidebarHost: AnyObject {
    func sidebarOpen(_ entry: SidebarEntry, newTab: Bool)
    func drop(_ urls: [URL], into folder: URL?, copy: Bool)
}

@MainActor
final class Sidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var host: SidebarHost?
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    private var sections: [SidebarEntry] = []
    private var quietly = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("entry"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.target = self
        outline.action = #selector(clicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        reload()

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Coming back from Finder: pick up favourites added or removed there, and fresh drive space.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func folder(_ title: String, _ url: URL, _ symbol: String) -> SidebarEntry {
            SidebarEntry(title, icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil), url: url, kind: .folder)
        }

        let quick = SidebarEntry("Quick access", kind: .section)
        quick.children = [
            folder("Home", home, "house"),
            folder("Desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            folder("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            folder("Documents", home.appendingPathComponent("Documents"), "doc"),
            folder("Pictures", home.appendingPathComponent("Pictures"), "photo"),
            folder("Music", home.appendingPathComponent("Music"), "music.note"),
            folder("Movies", home.appendingPathComponent("Movies"), "film"),
            folder("Applications", URL(fileURLWithPath: "/Applications"), "square.grid.3x3"),
        ]
        // Then Finder's own Favorites (minus duplicates and whole drives, which are under This Mac), then our pins.
        func listed(_ url: URL) -> Bool { quick.children.contains { $0.url?.standardizedFileURL == url.standardizedFileURL } }
        let volumes = Set((fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map(\.standardizedFileURL))
        for (name, url) in FinderFavorites.load() where !listed(url) && !volumes.contains(url.standardizedFileURL) {
            quick.children.append(folder(name, url, "star"))
        }
        for url in Settings.shared.pinned where !listed(url) {
            let entry = folder(url.lastPathComponent, url, "pin")
            entry.pinned = true
            quick.children.append(entry)
        }

        let mac = SidebarEntry("This Mac", kind: .section)
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: DriveInfo.keys, options: [.skipHiddenVolumes]) ?? [] {
            let drive = DriveInfo.read(url)
            let entry = SidebarEntry(drive.name,
                                     icon: NSImage(systemSymbolName: drive.connection == "Internal" ? "internaldrive" : "externaldrive", accessibilityDescription: nil),
                                     url: url, kind: .volume)
            entry.tooltip = drive.summary
            if drive.isReadOnly {
                entry.subtitle = "Read-only"   // disk images and such: "0 free" would just look alarming
            } else if drive.total > 0 {
                entry.subtitle = "\(Self.short(drive.free)) free of \(Self.short(drive.total))"
                entry.usedFraction = drive.usedFraction
            }
            mac.children.append(entry)
        }

        let system = SidebarEntry("System", kind: .section)
        system.children = [
            folder("Your Library", home.appendingPathComponent("Library"), "books.vertical"),
            folder("Library", URL(fileURLWithPath: "/Library"), "building.columns"),
            folder("Utilities", URL(fileURLWithPath: "/Applications/Utilities"), "wrench.and.screwdriver"),
            folder("Temporary files", URL(fileURLWithPath: NSTemporaryDirectory()), "clock"),
        ]

        sections = [quick, mac, system]
        let saved = Settings.shared.savedSearches
        if !saved.isEmpty {
            let searches = SidebarEntry("Saved searches", kind: .section)
            searches.children = saved.map { SidebarEntry($0.name, icon: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil), kind: .search($0)) }
            sections.append(searches)
        }

        outline.reloadData()
        sections.forEach { outline.expandItem($0) }
    }

    /// "84 GB" rather than "84,47 GB", so it fits under a drive's name.
    private static func short(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.isAdaptive = false
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Highlights the entry for the folder being shown, without navigating.
    func highlight(_ url: URL?) {
        quietly = true
        defer { quietly = false }
        let all = sections.flatMap(\.children)
        if let url, let match = all.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            outline.selectRowIndexes([outline.row(forItem: match)], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
    }

    @objc private func clicked() {
        guard !quietly, let entry = outline.item(atRow: outline.clickedRow) as? SidebarEntry, !entry.isSection else { return }
        host?.sidebarOpen(entry, newTab: NSEvent.modifierFlags.contains(.command))
    }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarEntry)?.children.count ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarEntry)?.children[index] ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarEntry)?.isSection ?? false }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarEntry)?.isSection ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? SidebarEntry)?.isSection ?? true) }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarEntry)?.subtitle != nil ? 40 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? SidebarEntry else { return nil }
        if entry.isSection {
            let label = NSTextField(labelWithString: entry.title)
            label.font = .boldSystemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let cell = NSTableCellView()
        let icon = NSImageView(image: entry.icon ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: entry.title)
        title.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let subtitle = entry.subtitle {
            let bar = CapacityBar(used: entry.usedFraction ?? 0)
            bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            bar.isHidden = entry.usedFraction == nil
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 10)
            sub.textColor = .secondaryLabelColor
            stack.addArrangedSubview(bar)
            stack.addArrangedSubview(sub)
        }
        let row = NSStackView(views: [icon, stack])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        cell.textField = title
        cell.toolTip = entry.tooltip
        cell.imageView = icon
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                     row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                                     row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                     icon.widthAnchor.constraint(equalToConstant: 16)])
        return cell
    }

    // MARK: Drops: drag files onto a sidebar folder to move them there

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let entry = item as? SidebarEntry, entry.url != nil, index == NSOutlineViewDropOnItemIndex else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = (item as? SidebarEntry)?.url else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        host?.drop(urls, into: folder, copy: NSEvent.modifierFlags.contains(.option))
        return true
    }
}

extension Sidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = outline.item(atRow: outline.clickedRow) as? SidebarEntry, !entry.isSection else { return }
        let open = menu.addItem(withTitle: "Open in New Tab", action: #selector(openInTab), keyEquivalent: "")
        open.target = self
        open.representedObject = entry
        if entry.pinned {
            let unpin = menu.addItem(withTitle: "Unpin from Quick access", action: #selector(unpin), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = entry
        }
        if case .search(let saved) = entry.kind {
            let delete = menu.addItem(withTitle: "Delete Saved Search", action: #selector(deleteSearch), keyEquivalent: "")
            delete.target = self
            delete.representedObject = saved.name
        }
        if case .volume = entry.kind, let url = entry.url {
            let info = menu.addItem(withTitle: "More Info…", action: #selector(moreInfo), keyEquivalent: "")
            info.target = self
            info.representedObject = url
        }
        if case .volume = entry.kind, let url = entry.url, (try? url.resourceValues(forKeys: [.volumeIsEjectableKey]).volumeIsEjectable) == true {
            let eject = menu.addItem(withTitle: "Eject", action: #selector(eject), keyEquivalent: "")
            eject.target = self
            eject.representedObject = url
        }
    }

    @objc private func openInTab(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? SidebarEntry { host?.sidebarOpen(entry, newTab: true) }
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? SidebarEntry)?.url else { return }
        Settings.shared.pinned.removeAll { $0 == url }
    }

    @objc private func deleteSearch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.savedSearches.removeAll { $0.name == name }
    }

    @objc private func moreInfo(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { DriveWindow.show(url) }
    }

    @objc private func eject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { NSAlert(error: error).runModal() }
    }
}

/// A drive's used space, drawn like Explorer's "This PC" bars: blue, red when over 90% full.
/// Purely a picture (not a control), so it can't be dragged or clicked.
final class CapacityBar: NSView {
    private let used: Double

    init(used: Double) {
        self.used = min(max(used, 0), 1)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * used, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        (used > 0.9 ? NSColor.systemRed : NSColor.systemBlue).setFill()
        filled.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the sidebar row underneath
}
