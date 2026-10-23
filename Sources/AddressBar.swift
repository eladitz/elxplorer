// The address bar: clickable breadcrumbs that turn into a typeable path (click the empty part, or ⌘L).

import AppKit

@MainActor
final class AddressBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((String) -> Void)?
    private let crumbs = Crumbs()
    private let field = NSTextField()
    private(set) var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumbs.pathStyle = .standard
        crumbs.focusRingType = .none
        crumbs.target = self
        crumbs.action = #selector(crumbClicked)
        crumbs.onEmptyClick = { [weak self] in self?.edit() }
        crumbs.wantsLayer = true
        crumbs.layer?.cornerRadius = 6
        crumbs.backgroundColor = .textBackgroundColor
        field.placeholderString = "Type a path, e.g. ~/Documents"
        field.delegate = self
        field.isHidden = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingHead
        for v in [crumbs, field] {
            // A long path shrinks (the middle folders collapse) instead of pushing buttons off the toolbar.
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         v.centerYAnchor.constraint(equalTo: centerYAnchor), v.heightAnchor.constraint(equalToConstant: 26)])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 500, height: 28) }

    func show(_ url: URL?, title: String? = nil) {
        self.url = url
        if let url { crumbs.url = url } else { crumbs.pathItems = [crumb(title ?? "")] }
    }

    private func crumb(_ title: String) -> NSPathControlItem {
        let item = NSPathControlItem()
        item.title = title
        return item
    }

    @objc private func crumbClicked() {
        guard let item = crumbs.clickedPathItem, let url = item.url else { return }
        onNavigate?(url.path)
    }

    func edit() {
        field.stringValue = url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        crumbs.isHidden = true
        field.isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func stopEditing() {
        field.isHidden = true
        crumbs.isHidden = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            stopEditing()
            onNavigate?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            stopEditing()
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { stopEditing() }

    /// Tab completes the last part of the path, like a terminal (and cycles nothing: it fills the common prefix).
    private func complete(_ textView: NSTextView) {
        let typed = (field.stringValue as NSString).expandingTildeInPath
        let parent = typed.hasSuffix("/") ? typed : (typed as NSString).deletingLastPathComponent
        let partial = typed.hasSuffix("/") ? "" : (typed as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
        let matches = names.filter { $0.lowercased().hasPrefix(partial.lowercased()) && !$0.hasPrefix(".") }
            .filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent($0), isDirectory: &dir) && dir.boolValue }
        guard let first = matches.first else { NSSound.beep(); return }
        var common = first
        for m in matches.dropFirst() { while !m.lowercased().hasPrefix(common.lowercased()) { common.removeLast() } }
        var full = (parent as NSString).appendingPathComponent(matches.count == 1 ? first : common)
        if matches.count == 1 { full += "/" }
        field.stringValue = (full as NSString).abbreviatingWithTildeInPath
        textView.moveToEndOfDocument(nil)
    }
}

/// A path control that reports clicks on its empty trailing area (where Explorer turns the bar into text).
final class Crumbs: NSPathControl {
    var onEmptyClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if clickedPathItem == nil { onEmptyClick?() }
    }
}
