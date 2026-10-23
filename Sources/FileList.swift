// The file listing: a Details table (the default, like Explorer) or a grid of large icons.

import AppKit
import QuickLookThumbnailing

enum Row {
    case header(String, Int)
    case item(FileItem)

    var item: FileItem? { if case .item(let i) = self { return i }; return nil }
}

/// What the list asks its window to do.
@MainActor
protocol FileListHost: AnyObject {
    func open(_ items: [FileItem])
    func rename(_ item: FileItem, to name: String)
    func contextMenu(for items: [FileItem]) -> NSMenu
    func selectionChanged()
    func goBack()
    func trash(permanently: Bool)
    func drop(_ urls: [URL], into folder: URL?, copy: Bool)
    func sortChanged()
    func togglePreviewPanel()
    func elconvoWheel() -> Bool
}

struct Column {
    let id: String
    let title: String
    let width: CGFloat
    let hiddenByDefault: Bool
    var rightAligned = false
}

@MainActor
final class FileList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                      NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var host: FileListHost?
    let scroll = NSScrollView()
    let table = FileTable()
    let grid = FileGrid()
    private(set) var rows: [Row] = []
    private var searching = false
    private var renaming: FileItem?
    private var applyingSort = false   // the table also reports sort changes it makes itself (e.g. restoring columns)

    static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 280, hiddenByDefault: false),
        Column(id: "modified", title: "Date modified", width: 150, hiddenByDefault: false),
        Column(id: "kind", title: "Type", width: 150, hiddenByDefault: false),
        Column(id: "size", title: "Size", width: 90, hiddenByDefault: false, rightAligned: true),
        Column(id: "created", title: "Date created", width: 150, hiddenByDefault: true),
        Column(id: "tags", title: "Tags", width: 120, hiddenByDefault: true),
        Column(id: "folder", title: "Folder", width: 280, hiddenByDefault: true),
    ]

    override init() {
        super.init()
        for c in Self.columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = 50
            col.maxWidth = c.id == "name" ? 900 : 600   // a huge window can't leave a giant column behind
            col.isHidden = c.hiddenByDefault
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            if c.rightAligned { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        // One autosave name for every window: column widths, order and visibility are the same in every folder.
        table.autosaveName = "ElxplorerDetailsColumns"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        // Columns are sized by fitColumns(): Name absorbs width changes, the others keep the widths you set.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.list = self
        table.registerForDraggedTypes([.fileURL])
        // Other apps (browsers, Mail, chat) ask for a copy or a link; offer every kind so any of them can take it.
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.headerView?.menu = columnMenu()
        // The saved layout may come from a moment a search was showing; Folder belongs only to search results.
        table.tableColumn(withIdentifier: .init("folder"))?.isHidden = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 118, height: 128)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        grid.collectionViewLayout = layout
        grid.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.list = self
        grid.backgroundColors = [.textBackgroundColor]
        // Drag items out to other apps (a browser's upload box, Mail, the desktop) and drop files in.
        grid.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.registerForDraggedTypes([.fileURL])

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true   // only appears when the list is narrower than its columns
        scroll.autohidesScrollers = true
        // Whenever the list gets wider or narrower (window resize, preview pane, sidebar), Name absorbs
        // the change so the other columns always stay in view.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitColumns() }
        }
        NotificationCenter.default.addObserver(forName: FolderSizes.updated, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let url = note.object as? URL,
                      let row = self.rows.firstIndex(where: { $0.item?.url == url }) else { return }
                let column = self.table.column(withIdentifier: .init("size"))
                if column >= 0 { self.table.reloadData(forRowIndexes: [row], columnIndexes: [column]) }
                self.host?.selectionChanged()   // the status bar's selection total may include it
            }
        }
        applyViewMode()
        applySort()
    }

    // MARK: Content

    func setRows(_ rows: [Row], searching: Bool) {
        let keep = Set(selectedItems.map(\.url))
        // Show or hide the Folder column while the table still describes the old rows: toggling a
        // column redraws the visible rows immediately.
        if self.searching != searching {
            self.searching = searching
            table.tableColumn(withIdentifier: .init("folder"))?.isHidden = !searching
        }
        self.rows = rows
        // Stop measuring folders that are no longer listed (e.g. after leaving a big folder).
        FolderSizes.shared.keepOnly(Set(rows.compactMap { $0.item?.isFolder == true ? $0.item?.url : nil }))
        table.reloadData()
        grid.reloadData()
        select(keep)
    }

    var items: [FileItem] { rows.compactMap(\.item) }

    var selectedItems: [FileItem] {
        if isGrid { return grid.selectionIndexPaths.sorted().compactMap { rows.indices.contains($0.item) ? rows[$0.item].item : nil } }
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].item : nil }
    }

    func select(_ urls: Set<URL>) {
        let wanted = Set(urls.map(\.canonicalPath))
        let indexes = IndexSet(rows.indices.filter { rows[$0].item.map { wanted.contains($0.url.canonicalPath) } ?? false })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        if let first = indexes.first {
            table.scrollRowToVisible(first)
            if isGrid { grid.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge) }
        }
    }

    var isGrid: Bool { Settings.shared.viewMode == "icons" }
    var focusView: NSView { isGrid ? grid : table }

    func fitColumns() {
        guard !isGrid, let name = table.tableColumn(withIdentifier: .init("name")) else { return }
        let available = scroll.contentView.bounds.width
        let spacing = table.intercellSpacing.width
        let others = table.tableColumns.filter { !$0.isHidden && $0 !== name }.reduce(0) { $0 + $1.width + spacing }
        let target = min(name.maxWidth, max(140, available - others - spacing - 2))
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    func applyViewMode() {
        scroll.documentView = isGrid ? grid : table
        if isGrid { grid.reloadData() } else { table.reloadData() }
    }

    func applySort() {
        let s = Settings.shared
        applyingSort = true
        table.sortDescriptors = [NSSortDescriptor(key: s.sortKey, ascending: s.ascending)]
        applyingSort = false
    }

    func redrawVisible() {
        table.reloadData()
        grid.reloadData()
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, let item = rows[row].item else { return }
        host?.open([item])
    }

    // MARK: Rename (F2)

    func beginRename(_ item: FileItem? = nil) {
        guard let item = item ?? selectedItems.first else { return }
        if isGrid {
            // The grid has no in-place editor; a small prompt does the job.
            let alert = NSAlert()
            alert.messageText = "Rename"
            let field = NSTextField(string: item.name)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn { host?.rename(item, to: field.stringValue) }
            return
        }
        guard let row = rows.firstIndex(where: { $0.item === item }) else { return }
        renaming = item
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let column = table.column(withIdentifier: .init("name"))
        guard column >= 0, let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        field.stringValue = item.name   // edit the full name, extension included
        field.isEditable = true
        field.delegate = self
        table.window?.makeFirstResponder(field)
        // Select the name without its extension, like Windows.
        let base = item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, let item = renaming else { return }
        field.isEditable = false
        renaming = nil
        let movement = (note.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.cancel.rawValue || field.stringValue == item.name {
            field.stringValue = item.displayName
        } else {
            host?.rename(item, to: field.stringValue)
        }
        table.window?.makeFirstResponder(table)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let item = renaming {
            (control as? NSTextField)?.stringValue = item.name
            textView.window?.makeFirstResponder(table)   // ends editing with no change
            return true
        }
        return false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if rows.indices.contains(row), case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].item != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title, let count):
            let cell = reuse(tableView, "header", withIcon: false)
            cell.textField?.stringValue = "\(title) (\(count))"
            cell.textField?.font = .boldSystemFont(ofSize: 12)
            return cell
        case .item(let item):
            guard let id = tableColumn?.identifier.rawValue else { return nil }
            let cell = reuse(tableView, id, withIcon: id == "name")
            let text: String
            switch id {
            case "name": text = item.displayName; cell.imageView?.image = item.icon
            case "modified": text = item.modified.map(Format.date.string(from:)) ?? ""
            case "created": text = item.created.map(Format.date.string(from:)) ?? ""
            case "kind": text = item.kind
            case "size":
                if item.isFolder && Settings.shared.folderSizes {
                    text = FolderSizes.shared.size(of: item.url).map { Format.size($0) } ?? "Calculating…"
                } else {
                    text = Format.size(item.size)
                }
            case "tags": text = item.tags.joined(separator: ", ")
            case "folder": text = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            default: text = ""
            }
            cell.textField?.stringValue = text
            cell.textField?.alignment = id == "size" ? .right : .left
            cell.textField?.textColor = id == "name" ? .labelColor : .secondaryLabelColor
            cell.alphaValue = Clipboard.cutURLs.contains(item.url) || item.isHidden ? 0.5 : 1
            return cell
        }
    }

    private func reuse(_ table: NSTableView, _ id: String, withIcon: Bool) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell-" + id)
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.cell?.truncatesLastVisibleLine = true
        cell.addSubview(text)
        cell.textField = text
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { host?.selectionChanged() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSort, let d = tableView.sortDescriptors.first, let key = d.key else { return }
        let s = Settings.shared
        if s.sortKey != key || s.ascending != d.ascending {
            s.sortKey = key
            s.ascending = d.ascending
            host?.sortChanged()
        }
    }

    // Typing a name jumps to it (type-select), using the visible name.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "name" else { return nil }
        return rows[row].item?.displayName
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows[row].item?.url as NSURL?
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Dropping onto a folder row goes into that folder; anywhere else, into the folder being shown.
        if op == .on, rows.indices.contains(row), let item = rows[row].item, item.isFolder { return dragOperation(info) }
        tableView.setDropRow(-1, dropOperation: .on)
        return searching ? [] : dragOperation(info)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let target = row >= 0 && rows.indices.contains(row) ? rows[row].item?.url : nil
        host?.drop(urls, into: target, copy: dragOperation(info) == .copy)
        return true
    }

    /// Option copies; otherwise move, like dragging within a drive in Explorer.
    private func dragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    // MARK: Column chooser (right-click the header)

    private func columnMenu() -> NSMenu {
        let menu = NSMenu()
        for c in Self.columns where c.id != "name" && c.id != "folder" {
            let item = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            menu.addItem(item)
        }
        menu.delegate = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let col = table.tableColumn(withIdentifier: .init(id)) else { return }
        col.isHidden.toggle()
    }

    // MARK: Icons grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: IconItem.id, for: indexPath) as! IconItem
        switch rows[indexPath.item] {
        case .header(let title, let count):
            view.show(title: "\(title) (\(count))", icon: nil, dimmed: false)
        case .item(let item):
            view.show(title: item.displayName, icon: item.icon, dimmed: Clipboard.cutURLs.contains(item.url) || item.isHidden)
            view.loadThumbnail(item.url)
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter { rows[$0.item].item != nil }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { host?.selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { host?.selectionChanged() }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { rows.indices.contains($0.item) && rows[$0.item].item != nil }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        rows[indexPath.item].item?.url as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // Onto a folder icon: into that folder. Anywhere else: into the folder being shown.
        let index = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, rows.indices.contains(index), rows[index].item?.isFolder == true { return dragOperation(info) }
        if searching { return [] }
        dropOperation.pointee = .before
        return dragOperation(info)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let target = dropOperation == .on && rows.indices.contains(indexPath.item) && rows[indexPath.item].item?.isFolder == true
            ? rows[indexPath.item].item?.url : nil
        host?.drop(urls, into: target, copy: dragOperation(info) == .copy)
        return true
    }
}

extension FileList: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String else { continue }
            item.state = table.tableColumn(withIdentifier: .init(id))?.isHidden == false ? .on : .off
        }
    }
}

// MARK: - Keyboard: Explorer's keys

@MainActor
private func handleKey(_ event: NSEvent, list: FileList?) -> Bool {
    guard let list, let host = list.host else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch event.keyCode {
    case 36, 76:   // Return / Enter: open
        host.open(list.selectedItems); return true
    case 120:      // F2: rename
        list.beginRename(); return true
    case 51 where flags.contains(.command):   // ⌘⌫: to the Trash
        host.trash(permanently: flags.contains(.option)); return true
    case 51:       // Backspace: back, like Explorer
        host.goBack(); return true
    case 117:      // Delete (fn⌫): to the Trash; with Shift, permanently
        host.trash(permanently: flags.contains(.shift)); return true
    case 49 where flags.isEmpty:   // Space: Quick Look
        host.togglePreviewPanel(); return true
    default:
        return false
    }
}

final class FileTable: NSTableView {
    weak var list: FileList?

    override func keyDown(with event: NSEvent) {
        if !handleKey(event, list: list) { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        guard let list, let host = list.host else { return nil }
        if event.modifierFlags.contains(.option), host.elconvoWheel() { return nil }
        return host.contextMenu(for: list.selectedItems)
    }
}

final class FileGrid: NSCollectionView {
    weak var list: FileList?

    override func keyDown(with event: NSEvent) {
        if !handleKey(event, list: list) { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let list, !list.selectedItems.isEmpty { list.host?.open(list.selectedItems) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index] }
        } else {
            selectionIndexPaths = []
        }
        guard let list, let host = list.host else { return nil }
        if event.modifierFlags.contains(.option), host.elconvoWheel() { return nil }
        return host.contextMenu(for: list.selectedItems)
    }
}

final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconItem")
    private static var thumbnails = NSCache<NSURL, NSImage>()
    private var current: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        view.addSubview(label)
        imageView = image
        textField = label
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 80), image.heightAnchor.constraint(equalToConstant: 80),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
    }

    func show(title: String, icon: NSImage?, dimmed: Bool) {
        textField?.stringValue = title
        imageView?.image = icon
        view.alphaValue = dimmed ? 0.5 : 1
        current = nil
    }

    /// Real thumbnails for pictures, videos, PDFs and so on; the type icon stays until one arrives.
    func loadThumbnail(_ url: URL) {
        current = url
        if let cached = Self.thumbnails.object(forKey: url as NSURL) { imageView?.image = cached; return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 80, height: 80),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                Self.thumbnails.setObject(image, forKey: url as NSURL)
                if self?.current == url { self?.imageView?.image = image }
            }
        }
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }
}
