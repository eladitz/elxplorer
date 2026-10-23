// One Explorer window (or tab): toolbar with address bar and search, the sidebar, the file list,
// the preview pane and the status bar, plus every file action.

import AppKit
import Quartz

@MainActor
final class Browser: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
                     NSMenuItemValidation, FileListHost, SidebarHost, QLPreviewPanelDataSource, QLPreviewPanelDelegate,
                     NSSplitViewDelegate {
    static private(set) var all: [Browser] = []

    private(set) var folder: URL?
    private var history: [URL] = []
    private var future: [URL] = []
    private var items: [FileItem] = []
    private var watcher: FolderWatcher?
    private var loadToken = 0
    private var shownHidden = Settings.shared.showHidden
    private var pendingSelection: Set<URL> = []
    private var pendingRename: URL?

    private var query = SearchQuery()
    private var searchRun: SearchRun?
    private var results: [FileItem] = []
    private var searchTimer: Timer?
    private var searchNote = ""
    private var searching: Bool { query.isActive }

    let list = FileList()
    let sidebar = Sidebar()
    let address = AddressBar()
    let searchField = NSSearchField()
    let preview = PreviewPane()
    private let status = NSTextField(labelWithString: "")
    private let searchBar = NSStackView()
    private let scopeLabel = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let menuBar = WindowMenuBar()
    private var menuBarHeight: NSLayoutConstraint!
    private var searchBarHeight: NSLayoutConstraint!

    // MARK: Window

    /// The size you last gave a window, trimmed to the screen so a bad value can't shrink or stretch it.
    static var savedSize: NSSize {
        let d = UserDefaults.standard
        let fallback = NSSize(width: 1100, height: 680)
        let w = d.double(forKey: "windowWidth"), h = d.double(forKey: "windowHeight")
        guard w > 560, h > 360 else { return fallback }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame.size ?? fallback
        guard w <= screen.width, h <= screen.height else { return fallback }
        return NSSize(width: w, height: h)
    }

    init(url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.savedSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "Elxplorer"
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden   // the address bar says where you are; tabs still show the folder name
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildContent()
        Self.all.append(self)
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        // Sorted by size: put folders in their place once all their sizes are in (not row by row, which jumps).
        NotificationCenter.default.addObserver(forName: FolderSizes.idle, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if Settings.shared.sortKey == "size" { self?.rebuild() } }
        }
        navigate(to: url, record: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// New windows open centred on the screen you're working on, at the size you last used.
    func placeOnPointerScreen() {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, let screen = window.screen?.visibleFrame.size else { return }
        let size = window.frame.size
        guard size.width <= screen.width, size.height <= screen.height else { return }
        UserDefaults.standard.set(size.width, forKey: "windowWidth")
        UserDefaults.standard.set(size.height, forKey: "windowHeight")
    }

    func windowWillClose(_ notification: Notification) {
        searchRun?.cancel()
        watcher = nil
        Self.all.removeAll { $0 === self }
    }

    // The "+" in the tab bar.
    @objc override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openTab(FileManager.default.homeDirectoryForCurrentUser, beside: self)
    }

    private func buildContent() {
        list.host = self
        sidebar.host = self
        address.onNavigate = { [weak self] text in self?.go(toTyped: text) }

        let content = NSView()
        searchBar.orientation = .horizontal
        searchBar.spacing = 8
        searchBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBar.addArrangedSubview(scopeLabel)
        searchBar.addArrangedSubview(popup([("names", "Names"), ("contents", "Names & contents")], tag: 0))
        searchBar.addArrangedSubview(popup(SearchQuery.kinds, tag: 1))
        searchBar.addArrangedSubview(popup(SearchQuery.dates, tag: 2))
        searchBar.addArrangedSubview(popup(SearchQuery.sizes, tag: 3))
        let save = NSButton(title: "Save Search", target: self, action: #selector(saveSearch))
        save.bezelStyle = .rounded
        searchBar.addArrangedSubview(save)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close search")!, target: self, action: #selector(closeSearch))
        close.isBordered = false
        searchBar.addArrangedSubview(close)
        searchBar.isHidden = true

        split.isVertical = true
        split.dividerStyle = .thin
        // Frame-based panes: Elxplorer works out the widths itself (see "Pane sizes"), so they're predictable
        // and nothing inside them can ever resize the window.
        for pane in [sidebar.scroll, list.scroll, preview] as [NSView] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            split.addSubview(pane)
        }
        split.delegate = self
        preview.isHidden = true   // shown by updatePreview() when wanted

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        for v in [menuBar, searchBar, split, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        searchBarHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        menuBarHeight = menuBar.heightAnchor.constraint(equalToConstant: Settings.shared.showMenuBar ? 26 : 0)
        menuBar.isHidden = !Settings.shared.showMenuBar
        NSLayoutConstraint.activate([
            menuBar.topAnchor.constraint(equalTo: content.topAnchor),
            menuBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            menuBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            menuBarHeight,
            searchBar.topAnchor.constraint(equalTo: menuBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchBarHeight,
            split.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 3),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        window?.contentView = content
    }

    private func popup(_ options: [(String, String)], tag: Int) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.controlSize = .small
        p.font = .systemFont(ofSize: 11)
        for (id, title) in options {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = id
        }
        p.tag = tag
        p.target = self
        p.action = #selector(filterChanged(_:))
        return p
    }

    // MARK: Pane sizes (sidebar | list | preview)

    static let sidebarMin: CGFloat = 150, sidebarMax: CGFloat = 420
    static let previewMin: CGFloat = 160, previewMaxShare: CGFloat = 0.6
    static let listMin: CGFloat = 260

    /// Lays the three panes out: the sidebar and preview keep their widths, the list gets the rest.
    /// When space runs short, the preview gives way first, then the sidebar, down to their minimums.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanes()
    }

    private func layoutPanes() {
        let total = split.bounds.width, height = split.bounds.height, gap = split.dividerThickness
        let s = Settings.shared
        var side = min(max(s.sidebarWidth, Self.sidebarMin), Self.sidebarMax)
        var pane: CGFloat = 0
        if !preview.isHidden {
            pane = s.previewWidth > 0 ? s.previewWidth : total * 0.3
            pane = min(max(pane, Self.previewMin), max(Self.previewMin, total * Self.previewMaxShare))
        }
        let gaps = gap * (preview.isHidden ? 1 : 2)
        var listWidth = total - side - pane - gaps
        if listWidth < Self.listMin, !preview.isHidden {
            let give = min(Self.listMin - listWidth, pane - Self.previewMin)
            pane -= give; listWidth += give
        }
        if listWidth < Self.listMin {
            let give = min(Self.listMin - listWidth, side - Self.sidebarMin)
            side -= give; listWidth += give
        }
        listWidth = max(0, listWidth)
        sidebar.scroll.frame = NSRect(x: 0, y: 0, width: side, height: height)
        list.scroll.frame = NSRect(x: side + gap, y: 0, width: listWidth, height: height)
        preview.frame = NSRect(x: side + gap + listWidth + gap, y: 0, width: pane, height: height)
        list.fitColumns()
        split.needsDisplay = true   // repaint the dividers where they now are (none left behind)
    }

    /// No divider line beside the list while the preview is closed.
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt index: Int) -> Bool { index == 1 && preview.isHidden }

    /// Divider drag limits: sidebar 150–420, list at least 260, preview from 160 up to 60% of the window.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? Self.sidebarMin
            : max(split.subviews[0].frame.maxX + split.dividerThickness + Self.listMin, split.bounds.width * (1 - Self.previewMaxShare))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let total = split.bounds.width
        return index == 0 ? min(Self.sidebarMax, total - Self.listMin - (preview.isHidden ? 0 : Self.previewMin))
            : total - Self.previewMin
    }

    /// A thin divider is easy to miss; give it a few more points to grab.
    func splitView(_ splitView: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt index: Int) -> NSRect {
        proposed.insetBy(dx: -4, dy: 0)
    }

    /// Remember the widths you drag the dividers to.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .leftMouseDragged, let index = notification.userInfo?["NSSplitViewDividerIndex"] as? Int else { return }
        if index == 0 { Settings.shared.sidebarWidth = sidebar.scroll.frame.width }
        if index == 1, !preview.isHidden { Settings.shared.previewWidth = preview.frame.width }
    }

    // MARK: Toolbar

    private enum Item {
        static let back = NSToolbarItem.Identifier("back"), forward = NSToolbarItem.Identifier("forward")
        static let up = NSToolbarItem.Identifier("up"), refresh = NSToolbarItem.Identifier("refresh")
        static let address = NSToolbarItem.Identifier("address"), search = NSToolbarItem.Identifier("search")
        static let newFolder = NSToolbarItem.Identifier("newFolder"), cut = NSToolbarItem.Identifier("cut")
        static let copy = NSToolbarItem.Identifier("copy"), paste = NSToolbarItem.Identifier("paste")
        static let delete = NSToolbarItem.Identifier("delete"), view = NSToolbarItem.Identifier("view")
        static let preview = NSToolbarItem.Identifier("preview"), hidden = NSToolbarItem.Identifier("hidden")
        static let terminal = NSToolbarItem.Identifier("terminal")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ElxplorerToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true   // right-click the toolbar to add or remove buttons
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.up, Item.refresh, Item.address, Item.preview, Item.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.up, Item.refresh, Item.address, Item.search, Item.newFolder, Item.cut, Item.copy,
         Item.paste, Item.delete, Item.view, Item.preview, Item.hidden, Item.terminal, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.isBordered = true
            item.visibilityPriority = .high   // navigation buttons never go to the overflow menu
            return item
        }
        switch id {
        case Item.back: return button("Back", "chevron.left", #selector(goBack(_:)))
        case Item.forward: return button("Forward", "chevron.right", #selector(goForward(_:)))
        case Item.up: return button("Up", "arrow.up", #selector(goUp(_:)))
        case Item.refresh: return button("Refresh", "arrow.clockwise", #selector(refresh(_:)))
        case Item.newFolder: return button("New Folder", "folder.badge.plus", #selector(newFolder(_:)))
        case Item.cut: return button("Cut", "scissors", #selector(cut(_:)))
        case Item.copy: return button("Copy", "doc.on.doc", #selector(copy(_:)))
        case Item.paste: return button("Paste", "doc.on.clipboard", #selector(paste(_:)))
        case Item.delete: return button("Delete", "trash", #selector(moveToTrash(_:)))
        case Item.view: return button("Change View", "square.grid.2x2", #selector(toggleView(_:)))
        case Item.preview: return button("Preview Pane", "sidebar.right", #selector(togglePreviewPane(_:)))
        case Item.hidden: return button("Hidden Files", "eye", #selector(toggleHidden(_:)))
        case Item.terminal: return button("Open in Terminal", "terminal", #selector(openTerminal(_:)))
        case Item.address:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Address"
            item.paletteLabel = "Address"
            item.view = address
            item.visibilityPriority = .standard
            // Wide, but never so wide that Back/Forward/Up get pushed into the overflow menu.
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            address.widthAnchor.constraint(lessThanOrEqualToConstant: 900).isActive = true
            let preferred = address.widthAnchor.constraint(equalToConstant: 480)
            preferred.priority = .defaultLow
            preferred.isActive = true
            return item
        case Item.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = searchField
            item.preferredWidthForSearchField = 200
            searchField.delegate = self
            searchField.sendsSearchStringImmediately = false
            return item
        default: return nil
        }
    }

    // MARK: Navigation

    func navigate(to target: URL, record: Bool = true, select: Set<URL> = []) {
        let url = target.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            showError("“\((target.path as NSString).abbreviatingWithTildeInPath)” doesn't exist.")
            return
        }
        // A file: show it in its folder, selected (what "reveal" means everywhere else).
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        if !isDir.boolValue || isPackage {
            navigate(to: url.deletingLastPathComponent(), record: record, select: [url])
            return
        }
        if record, let folder, folder != url {
            history.append(folder)
            future.removeAll()
        }
        endSearch()
        folder = url
        let name = FileManager.default.displayName(atPath: url.path)
        window?.title = name
        window?.representedURL = url
        address.show(url)
        sidebar.highlight(url)
        searchField.placeholderString = "Search \(name)"
        watcher = FolderWatcher(url) { [weak self] in self?.reload() }
        pendingSelection = select
        reload()
        window?.makeFirstResponder(list.focusView)
    }

    func go(toTyped text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let path = (trimmed as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (folder ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(path)
        navigate(to: url)
    }

    private func reload() {
        guard let folder else { return }
        loadToken += 1
        let token = loadToken
        let hidden = Settings.shared.showHidden
        shownHidden = hidden
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.loadToken == token, self?.items.isEmpty == true { self?.status.stringValue = "Loading…" }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Loader.load(folder, showHidden: hidden) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, token == self.loadToken else { return }
                    switch result {
                    case .success(let loaded):
                        self.items = loaded
                        self.rebuild()
                        _ = started
                    case .failure(let error):
                        self.items = []
                        self.rebuild()
                        self.status.stringValue = "Can't open this folder: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func rebuild() {
        let s = Settings.shared
        let source = searching ? results : items
        let sizes = FolderSizes.shared
        let sorted = Sorter.sort(source, key: s.sortKey, ascending: s.ascending, foldersFirst: s.foldersFirst) {
            $0.isFolder && s.folderSizes ? sizes.cached($0.url) : $0.size
        }
        var rows: [Row] = []
        switch s.groupBy {
        case "type":
            let groups = Dictionary(grouping: sorted) { $0.isFolder ? "Folder" : $0.kind }
            for key in groups.keys.sorted(by: { $0 == "Folder" ? true : $1 == "Folder" ? false : $0.localizedStandardCompare($1) == .orderedAscending }) {
                rows.append(.header(key, groups[key]!.count))
                rows += groups[key]!.map(Row.item)
            }
        case "date":
            let groups = Dictionary(grouping: sorted) { Sorter.dateGroup($0.modified) }
            for key in Sorter.dateGroupOrder where groups[key] != nil {
                rows.append(.header(key, groups[key]!.count))
                rows += groups[key]!.map(Row.item)
            }
        default:
            rows = sorted.map(Row.item)
        }
        list.setRows(rows, searching: searching)
        if !pendingSelection.isEmpty {
            list.select(pendingSelection)
            pendingSelection = []
        }
        if let rename = pendingRename, let item = list.items.first(where: { $0.url == rename }) {
            pendingRename = nil
            list.beginRename(item)
        }
        updateStatus()
        updatePreview()
    }

    /// The pane shows when asked for (View ▸ Preview Pane), or by itself while a picture/video is selected.
    private func updatePreview() {
        let s = Settings.shared
        let chosen = list.selectedItems
        let wanted = s.showPreview || (s.autoPreviewMedia && chosen.count == 1 && chosen[0].isPreviewable)
        if wanted && preview.isHidden {
            preview.isHidden = false
            layoutPanes()
        } else if !wanted && !preview.isHidden {
            preview.isHidden = true
            layoutPanes()
        }
        if wanted { preview.show(chosen) }
    }

    private func settingsChanged() {
        menuBar.isHidden = !Settings.shared.showMenuBar
        menuBarHeight.constant = Settings.shared.showMenuBar ? 26 : 0
        if shownHidden != Settings.shared.showHidden { reload() }
        if list.scroll.documentView !== list.focusView { list.applyViewMode() }
        list.applySort()
        rebuild()
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = history.popLast() else { return }
        if let folder { future.append(folder) }
        navigate(to: previous, record: false, select: folder.map { [$0] } ?? [])
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = future.popLast() else { return }
        if let folder { history.append(folder) }
        navigate(to: next, record: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard let folder, folder.path != "/" else { return }
        navigate(to: folder.deletingLastPathComponent(), select: [folder])   // land on the folder we came from
    }

    @objc func refresh(_ sender: Any?) {
        FolderSizes.shared.forget(items.filter(\.isFolder).map(\.url))
        reload()
    }
    @objc func editAddress(_ sender: Any?) { address.edit() }
    @objc func goHome(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func goDesktop(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")) }
    @objc func goDownloads(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
    @objc func goDocuments(_ sender: Any?) { navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }

    // MARK: FileListHost

    func open(_ chosen: [FileItem]) {
        let folders = chosen.filter(\.isFolder)
        let files = chosen.filter { !$0.isFolder }
        for file in files { NSWorkspace.shared.open(file.url) }
        guard let first = folders.first else { return }
        navigate(to: first.url)
        for other in folders.dropFirst() { (NSApp.delegate as? AppDelegate)?.openTab(other.url, beside: self) }
    }

    func goBack() { goBack(nil) }

    func rename(_ item: FileItem, to name: String) {
        do {
            let renamed = try FileOps.rename(item.url, to: name)
            pendingSelection = [renamed]
            reload()
        } catch { showError(error.localizedDescription) }
    }

    func selectionChanged() {
        updateStatus()
        updatePreview()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func sortChanged() { rebuild() }

    func drop(_ urls: [URL], into target: URL?, copy: Bool) {
        guard let destination = target ?? folder else { return }
        // Dragged out and dropped back where they already are: nothing to do.
        if !copy, urls.allSatisfy({ $0.deletingLastPathComponent().canonicalPath == destination.canonicalPath }) { return }
        perform(copy ? "Copying" : "Moving", urls.count) { try FileOps.paste(urls, into: destination, move: !copy) }
    }

    func trash(permanently: Bool) {
        let urls = list.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        if permanently {
            let alert = NSAlert()
            alert.messageText = urls.count == 1 ? "Permanently delete “\(urls[0].lastPathComponent)”?" : "Permanently delete \(urls.count) items?"
            alert.informativeText = "This can't be undone; the items won't go to the Trash."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            perform("Deleting", urls.count) {
                for url in urls { try FileManager.default.removeItem(at: url) }
                return []
            }
        } else {
            NSWorkspace.shared.recycle(urls) { [weak self] _, error in
                MainActor.assumeIsolated {
                    if let error { self?.showError(error.localizedDescription) }
                    self?.reload()
                }
            }
        }
    }

    // MARK: Menu actions (also reached from the menu bar through the responder chain)

    private var selection: [URL] { list.selectedItems.map(\.url) }
    /// The folder an action applies to: a selected folder, or the one being shown.
    private var targetFolder: URL? {
        if let only = list.selectedItems.first, list.selectedItems.count == 1, only.isFolder { return only.url }
        return folder
    }

    @objc func openSelection(_ sender: Any?) { open(list.selectedItems) }
    @objc func cut(_ sender: Any?) { if !selection.isEmpty { Clipboard.copy(selection, cut: true) } }
    @objc func copy(_ sender: Any?) { if !selection.isEmpty { Clipboard.copy(selection, cut: false) } }

    @objc func paste(_ sender: Any?) { pasteInto(folder) }
    @objc func pasteIntoSelection(_ sender: Any?) { pasteInto(targetFolder) }

    private func pasteInto(_ destination: URL?) {
        guard let destination else { return }
        let (urls, cut) = Clipboard.contents
        guard !urls.isEmpty else { return }
        perform(cut ? "Moving" : "Copying", urls.count) { try FileOps.paste(urls, into: destination, move: cut) }
        if cut { Clipboard.pasted() }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selection.isEmpty ? [folder].compactMap { $0 } : selection
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func renameSelection(_ sender: Any?) { list.beginRename() }
    @objc func moveToTrash(_ sender: Any?) { trash(permanently: false) }
    @objc func deletePermanently(_ sender: Any?) { trash(permanently: true) }

    @objc func newFolder(_ sender: Any?) {
        guard let folder else { return }
        do {
            let url = try FileOps.newFolder(in: folder)
            pendingSelection = [url]
            pendingRename = url   // start typing its name straight away, as in Explorer
            reload()
        } catch { showError(error.localizedDescription) }
    }

    @objc func newTextDocument(_ sender: Any?) { newFile("New Text Document.txt", "") }
    @objc func newMarkdown(_ sender: Any?) { newFile("New Document.md", "") }
    @objc func newRichText(_ sender: Any?) { newFile("New Rich Text Document.rtf", "{\\rtf1\\ansi\\deff0 }") }
    @objc func newHTML(_ sender: Any?) { newFile("New Page.html", "<!doctype html>\n<html>\n<head><meta charset=\"utf-8\"><title></title></head>\n<body>\n\n</body>\n</html>\n") }

    private func newFile(_ name: String, _ contents: String) {
        guard let folder else { return }
        do {
            let url = try FileOps.newFile(name, in: folder)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            pendingSelection = [url]
            pendingRename = url
            reload()
        } catch { showError(error.localizedDescription) }
    }

    @objc func compress(_ sender: Any?) {
        let urls = selection
        guard !urls.isEmpty else { return }
        perform("Compressing", urls.count) { [try FileOps.zip(urls)] }
    }

    @objc func openTerminal(_ sender: Any?) {
        guard let dir = targetFolder else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func pinFolder(_ sender: Any?) {
        guard let dir = targetFolder, !Settings.shared.pinned.contains(dir) else { return }
        Settings.shared.pinned.append(dir)
    }

    @objc func showProperties(_ sender: Any?) {
        if let item = list.selectedItems.first { Properties.show(item) }
        else if let folder { Properties.show(FileItem(url: folder)) }
    }

    /// The escape hatch: the same files in Finder (asked for by name, so it works even when Elxplorer is the default).
    @objc func showInFinder(_ sender: Any?) {
        let targets = selection.isEmpty ? [folder].compactMap { $0 } : selection
        let list = targets.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        NSAppleScript(source: "tell application \"Finder\"\nreveal {\(list)}\nactivate\nend tell")?.executeAndReturnError(nil)
    }

    @objc func convertWithElconvo(_ sender: Any?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.itzkin.elconvo") else { return }
        NSWorkspace.shared.open(selection, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selection, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open With"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(selection, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openInNewTab(_ sender: Any?) {
        for item in list.selectedItems where item.isFolder { (NSApp.delegate as? AppDelegate)?.openTab(item.url, beside: self) }
    }

    @objc override func selectAll(_ sender: Any?) {
        if list.isGrid { list.grid.selectAll(sender) } else { list.table.selectAll(sender) }
    }

    @objc func find(_ sender: Any?) { window?.makeFirstResponder(searchField) }

    // View options
    @objc func showDetails(_ sender: Any?) { Settings.shared.viewMode = "details" }
    @objc func showIcons(_ sender: Any?) { Settings.shared.viewMode = "icons" }
    @objc func toggleView(_ sender: Any?) { Settings.shared.viewMode = list.isGrid ? "details" : "icons" }
    @objc func togglePreviewPane(_ sender: Any?) { Settings.shared.showPreview.toggle() }
    @objc func toggleAutoPreview(_ sender: Any?) { Settings.shared.autoPreviewMedia.toggle() }
    @objc func toggleMenuBar(_ sender: Any?) { Settings.shared.showMenuBar.toggle() }
    @objc func toggleHidden(_ sender: Any?) { Settings.shared.showHidden.toggle() }
    @objc func toggleExtensions(_ sender: Any?) { Settings.shared.showExtensions.toggle() }
    @objc func toggleFoldersFirst(_ sender: Any?) { Settings.shared.foldersFirst.toggle() }
    @objc func toggleFolderSizes(_ sender: Any?) { Settings.shared.folderSizes.toggle() }
    @objc func groupNone(_ sender: Any?) { Settings.shared.groupBy = "none" }
    @objc func groupByType(_ sender: Any?) { Settings.shared.groupBy = "type" }
    @objc func groupByDate(_ sender: Any?) { Settings.shared.groupBy = "date" }
    @objc func sortBy(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let s = Settings.shared
        if s.sortKey == key { s.ascending.toggle() } else { s.sortKey = key; s.ascending = key == "name" || key == "kind" }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let s = Settings.shared
        switch menuItem.action {
        case #selector(goBack(_:)): return !history.isEmpty
        case #selector(goForward(_:)): return !future.isEmpty
        case #selector(goUp(_:)): return folder.map { $0.path != "/" } ?? false
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(deletePermanently(_:)),
             #selector(compress(_:)), #selector(openSelection(_:)):
            return !selection.isEmpty
        case #selector(renameSelection(_:)): return list.selectedItems.count == 1
        case #selector(paste(_:)), #selector(pasteIntoSelection(_:)): return Clipboard.canPaste && !searching
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)), #selector(newMarkdown(_:)), #selector(newRichText(_:)), #selector(newHTML(_:)):
            return !searching
        case #selector(showDetails(_:)): menuItem.state = list.isGrid ? .off : .on
        case #selector(showIcons(_:)): menuItem.state = list.isGrid ? .on : .off
        case #selector(togglePreviewPane(_:)): menuItem.state = s.showPreview ? .on : .off
        case #selector(toggleAutoPreview(_:)): menuItem.state = s.autoPreviewMedia ? .on : .off
        case #selector(toggleMenuBar(_:)): menuItem.state = s.showMenuBar ? .on : .off
        case #selector(toggleHidden(_:)): menuItem.state = s.showHidden ? .on : .off
        case #selector(toggleExtensions(_:)): menuItem.state = s.showExtensions ? .on : .off
        case #selector(toggleFoldersFirst(_:)): menuItem.state = s.foldersFirst ? .on : .off
        case #selector(toggleFolderSizes(_:)): menuItem.state = s.folderSizes ? .on : .off
        case #selector(groupNone(_:)): menuItem.state = s.groupBy == "none" ? .on : .off
        case #selector(groupByType(_:)): menuItem.state = s.groupBy == "type" ? .on : .off
        case #selector(groupByDate(_:)): menuItem.state = s.groupBy == "date" ? .on : .off
        case #selector(sortBy(_:)): menuItem.state = (menuItem.representedObject as? String) == s.sortKey ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Context menu

    func contextMenu(for chosen: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        func add(_ title: String, _ action: Selector, key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
        func submenu(_ title: String, _ entries: [(String, Selector, Any?)]) {
            let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (t, a, obj) in entries {
                let i = sub.addItem(withTitle: t, action: a, keyEquivalent: "")
                i.target = self
                i.representedObject = obj
            }
            parent.submenu = sub
        }

        if chosen.isEmpty {
            submenu("View", [("Details", #selector(showDetails(_:)), nil), ("Large icons", #selector(showIcons(_:)), nil)])
            submenu("Sort by", FileList.columns.filter { $0.id != "tags" && ($0.id != "folder" || searching) }.map { ($0.title, #selector(sortBy(_:)), $0.id) })
            submenu("Group by", [("None", #selector(groupNone(_:)), nil), ("Type", #selector(groupByType(_:)), nil), ("Date modified", #selector(groupByDate(_:)), nil)])
            _ = add("Refresh", #selector(refresh(_:)), key: "r")
            menu.addItem(.separator())
            _ = add("Paste", #selector(paste(_:)), key: "v")
            menu.addItem(.separator())
            submenu("New", [("Folder", #selector(newFolder(_:)), nil), ("Text Document", #selector(newTextDocument(_:)), nil),
                            ("Markdown Document", #selector(newMarkdown(_:)), nil), ("Rich Text Document", #selector(newRichText(_:)), nil),
                            ("Web Page", #selector(newHTML(_:)), nil)])
            menu.addItem(.separator())
            _ = add("Open in Terminal", #selector(openTerminal(_:)))
            _ = add("Copy Path", #selector(copyPath(_:)))
            _ = add("Pin to Quick access", #selector(pinFolder(_:)))
            menu.addItem(.separator())
            _ = add("Properties", #selector(showProperties(_:)), key: "i")
            return menu
        }

        let open = add("Open", #selector(openSelection(_:)))
        open.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if chosen.contains(where: \.isFolder) { _ = add("Open in New Tab", #selector(openInNewTab(_:))) }
        if chosen.count == 1, let file = chosen.first, !file.isFolder {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: file.url).prefix(12)
            let parent = menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in apps {
                let i = sub.addItem(withTitle: FileManager.default.displayName(atPath: app.path), action: #selector(openWithApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = app
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                i.image = icon
            }
            sub.addItem(.separator())
            let other = sub.addItem(withTitle: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
            other.target = self
            parent.submenu = sub
        }
        menu.addItem(.separator())
        _ = add("Cut", #selector(cut(_:)), key: "x")
        _ = add("Copy", #selector(copy(_:)), key: "c")
        if chosen.count == 1, chosen[0].isFolder { _ = add("Paste into Folder", #selector(pasteIntoSelection(_:))) }
        _ = add("Copy as Path", #selector(copyPath(_:)), key: "c", [.command, .option])
        menu.addItem(.separator())
        if chosen.count == 1 { _ = add("Rename", #selector(renameSelection(_:))) }
        _ = add("Delete", #selector(moveToTrash(_:)), key: "\u{8}")
        menu.addItem(.separator())
        _ = add("Compress to ZIP", #selector(compress(_:)))
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.itzkin.elconvo") != nil, chosen.contains(where: { !$0.isFolder }) {
            _ = add("Convert with Elconvo", #selector(convertWithElconvo(_:)))
        }
        if chosen.count == 1, chosen[0].isFolder {
            _ = add("Pin to Quick access", #selector(pinFolder(_:)))
            _ = add("Open in Terminal", #selector(openTerminal(_:)))
        }
        _ = add("Show in Finder", #selector(showInFinder(_:)))
        menu.addItem(.separator())
        _ = add("Properties", #selector(showProperties(_:)), key: "i")
        return menu
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startSearch() }
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) { if sender.stringValue.isEmpty { closeSearch() } }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        let value = sender.selectedItem?.representedObject as? String ?? "any"
        switch sender.tag {
        case 0: query.contents = value == "contents"
        case 1: query.kind = value
        case 2: query.date = value
        default: query.size = value
        }
        startSearch()
    }

    private func startSearch() {
        query.text = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        searchRun?.cancel()
        searchRun = nil
        results = []
        guard let folder, query.isActive else {
            if !query.isActive { endSearch(keepBar: !searchBar.isHidden) }
            return
        }
        showSearchBar(true)
        let name = FileManager.default.displayName(atPath: folder.path)
        scopeLabel.stringValue = "Searching “\(name)” and everything inside it…"
        searchNote = ""
        let started = Date()
        searchRun = SearchRun(root: folder, query: query, showHidden: Settings.shared.showHidden, batch: { [weak self] found in
            self?.results += found
            self?.rebuild()
        }, done: { [weak self] limited in
            guard let self else { return }
            let time = String(format: "%.1f", Date().timeIntervalSince(started))
            self.scopeLabel.stringValue = "In “\(name)” and everything inside it · \(self.results.count) found in \(time)s"
            self.searchNote = limited ? " (first \(SearchRun.limit) shown)" : ""
            self.rebuild()
        })
        rebuild()
    }

    private func showSearchBar(_ show: Bool) {
        searchBar.isHidden = !show
        searchBarHeight.constant = show ? 32 : 0
    }

    @objc private func closeSearch() {
        searchField.stringValue = ""
        endSearch()
        rebuild()
        window?.makeFirstResponder(list.focusView)
    }

    private func endSearch(keepBar: Bool = false) {
        searchRun?.cancel()
        searchRun = nil
        results = []
        if !keepBar {
            query = SearchQuery()
            searchField.stringValue = ""
            for case let p as NSPopUpButton in searchBar.arrangedSubviews { p.selectItem(at: 0) }
            showSearchBar(false)
        }
    }

    @objc private func saveSearch() {
        guard let folder, query.isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Save this search"
        alert.informativeText = "It appears under Saved searches in the sidebar and re-runs whenever you open it."
        let field = NSTextField(string: query.text.isEmpty ? "My search" : query.text)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var saved = Settings.shared.savedSearches.filter { $0.name != field.stringValue }
        saved.append(SavedSearch(name: field.stringValue, root: folder.path, query: query.text, contents: query.contents,
                                 kind: query.kind, date: query.date, size: query.size))
        Settings.shared.savedSearches = saved
    }

    func run(_ saved: SavedSearch) {
        navigate(to: URL(fileURLWithPath: saved.root))
        searchField.stringValue = saved.query
        query = SearchQuery(text: saved.query, contents: saved.contents, kind: saved.kind, date: saved.date, size: saved.size)
        let values = [saved.contents ? "contents" : "names", saved.kind, saved.date, saved.size]
        for case let p as NSPopUpButton in searchBar.arrangedSubviews {
            if let i = p.itemArray.firstIndex(where: { $0.representedObject as? String == values[p.tag] }) { p.selectItem(at: i) }
        }
        startSearch()
    }

    // MARK: SidebarHost

    func sidebarOpen(_ entry: SidebarEntry, newTab: Bool) {
        if case .search(let saved) = entry.kind {
            run(saved)
            return
        }
        guard let url = entry.url else { return }
        if newTab { (NSApp.delegate as? AppDelegate)?.openTab(url, beside: self) } else { navigate(to: url) }
    }

    // MARK: Status bar

    private func updateStatus() {
        let shown = list.items
        var parts: [String] = []
        parts.append(searching ? "\(shown.count) found\(searchNote)" : "\(shown.count) item\(shown.count == 1 ? "" : "s")")
        let chosen = list.selectedItems
        if !chosen.isEmpty {
            let bytes = chosen.compactMap { $0.isFolder ? FolderSizes.shared.cached($0.url) : $0.size }.reduce(0, +)
            parts.append("\(chosen.count) selected" + (bytes > 0 ? " (\(Format.size(bytes)))" : ""))
        }
        if let folder, let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            parts.append("\(Format.size(free)) free")
        }
        status.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: Work and errors

    /// Runs a file operation off the main thread, then refreshes and selects what it produced.
    private func perform(_ verb: String, _ count: Int, _ work: @escaping () throws -> [URL]) {
        status.stringValue = "\(verb) \(count) item\(count == 1 ? "" : "s")…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let made): self.pendingSelection = Set(made)
                    case .failure(let error): self.showError(error.localizedDescription)
                    }
                    self.reload()
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Quick Look (Space)

    func togglePreviewPanel() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { list.selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        list.selectedItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys move through the list while the preview is open.
        if event.type == .keyDown { list.focusView.keyDown(with: event); return true }
        return false
    }
}

/// Explorer's classic in-window menu bar: File, Edit, View, Go, Window, opening the same menus as the
/// macOS menu bar (same items, same shortcuts, same enabled/disabled state).
@MainActor
final class WindowMenuBar: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        // Every top-level menu except the app's own (About, Quit), which macOS keeps for itself.
        for item in (NSApp.mainMenu?.items ?? []).dropFirst() {
            guard let menu = item.submenu else { continue }
            let button = NSButton(title: menu.title, target: self, action: #selector(open(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.contentTintColor = .labelColor
            button.setButtonType(.momentaryChange)
            stack.addArrangedSubview(button)
            button.identifier = NSUserInterfaceItemIdentifier(menu.title)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func open(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue,
              let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu else { return }
        let below = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: sender)
    }
}
