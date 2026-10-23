// The preview pane (Quick Look, which covers pictures, video, PDF, Office, 3D…) plus the file's details,
// and the Properties window.

import AppKit
import Quartz
import AVKit
import UniformTypeIdentifiers

enum Details {
    /// Readable facts about a file from Spotlight's metadata: dimensions, duration, camera, pages, source…
    static func facts(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        guard let md = MDItemCreateWithURL(nil, url as CFURL) else { return rows }
        func value(_ key: CFString) -> Any? { MDItemCopyAttribute(md, key) }
        func number(_ key: CFString) -> Double? { (value(key) as? NSNumber)?.doubleValue }

        if let w = number(kMDItemPixelWidth), let h = number(kMDItemPixelHeight) { rows.append(("Dimensions", "\(Int(w)) × \(Int(h))")) }
        if let s = number(kMDItemDurationSeconds), s > 0 {
            rows.append(("Length", Duration.seconds(s).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        if let codecs = value(kMDItemCodecs) as? [String], !codecs.isEmpty { rows.append(("Codecs", codecs.joined(separator: ", "))) }
        if let rate = number(kMDItemTotalBitRate) ?? number(kMDItemAudioBitRate) { rows.append(("Bit rate", "\(Int(rate / 1000)) kbps")) }
        let camera = [value(kMDItemAcquisitionMake) as? String, value(kMDItemAcquisitionModel) as? String].compactMap { $0 }
        if !camera.isEmpty { rows.append(("Camera", camera.joined(separator: " "))) }
        var exposure: [String] = []
        if let f = number(kMDItemFNumber) { exposure.append(String(format: "ƒ/%.1f", f)) }
        if let t = number(kMDItemExposureTimeSeconds), t > 0 { exposure.append(t < 1 ? "1/\(Int((1 / t).rounded()))s" : String(format: "%.1fs", t)) }
        if let iso = number(kMDItemISOSpeed) { exposure.append("ISO \(Int(iso))") }
        if let mm = number(kMDItemFocalLength) { exposure.append("\(Int(mm)) mm") }
        if !exposure.isEmpty { rows.append(("Exposure", exposure.joined(separator: "  "))) }
        if let pages = number(kMDItemNumberOfPages) { rows.append(("Pages", "\(Int(pages))")) }
        if let title = value(kMDItemTitle) as? String, !title.isEmpty { rows.append(("Title", title)) }
        if let authors = value(kMDItemAuthors) as? [String], !authors.isEmpty { rows.append(("Authors", authors.joined(separator: ", "))) }
        if let version = value(kMDItemVersion) as? String { rows.append(("Version", version)) }
        if let from = value(kMDItemWhereFroms) as? [String], let first = from.first { rows.append(("Downloaded from", first)) }
        if let lat = number(kMDItemLatitude), let lon = number(kMDItemLongitude) { rows.append(("Location", String(format: "%.5f, %.5f", lat, lon))) }
        return rows
    }
}

@MainActor
final class PreviewPane: NSView {
    // Pictures and video get their own viewers (sharp, scalable, real playback controls);
    // everything else goes through Quick Look.
    private let stage = NSView()
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private let picture = NSImageView()
    private let player = AVPlayerView()
    private var pictureJob = 0
    private let info = NSStackView()
    private var sizeJob: Thread?
    private var shown: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        preview.autostarts = true
        preview.shouldCloseWithWindow = false
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 4
        info.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        let infoScroll = NSScrollView()
        infoScroll.documentView = info
        infoScroll.hasVerticalScroller = true
        infoScroll.drawsBackground = false
        picture.imageScaling = .scaleProportionallyDown
        picture.animates = true   // GIFs play
        player.controlsStyle = .inline
        player.showsFullScreenToggleButton = true
        for v in [preview, picture, player] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: stage.topAnchor, constant: 8),
                                         v.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -8),
                                         v.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 8),
                                         v.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -8)])
        }
        for v in [stage, infoScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        info.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: topAnchor), stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor), stage.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.6),
            infoScroll.topAnchor.constraint(equalTo: stage.bottomAnchor), infoScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoScroll.trailingAnchor.constraint(equalTo: trailingAnchor), infoScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            info.widthAnchor.constraint(equalTo: infoScroll.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [FileItem]) {
        guard items.count == 1, let item = items.first else {
            shown = nil
            display(nil)
            fill(items.isEmpty ? [] : [("Selected", "\(items.count) items"),
                                       ("Size", Format.size(items.compactMap(\.size).reduce(0, +)))], title: nil)
            return
        }
        guard item.url != shown else { return }
        shown = item.url
        display(item)
        var rows: [(String, String)] = [("Type", item.kind),
                                         ("Location", (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)]
        if let s = item.size { rows.append(("Size", Format.size(s))) }
        if let m = item.modified { rows.append(("Modified", Format.date.string(from: m))) }
        if let c = item.created { rows.append(("Created", Format.date.string(from: c))) }
        if !item.tags.isEmpty { rows.append(("Tags", item.tags.joined(separator: ", "))) }
        rows += Details.facts(item.url)
        fill(rows, title: item.name)
        if item.isFolder { measure(item.url) }
    }

    private enum Viewer { case quickLook, picture, video }

    private func display(_ item: FileItem?) {
        player.player?.pause()
        let type = item?.typeID.flatMap(UTType.init)
        let viewer: Viewer = type == nil ? .quickLook
            : type!.conforms(to: .image) ? .picture
            : type!.conforms(to: .audiovisualContent) ? .video : .quickLook
        preview.isHidden = viewer != .quickLook
        picture.isHidden = viewer != .picture
        player.isHidden = viewer != .video
        preview.previewItem = viewer == .quickLook ? item?.url as NSURL? : nil
        player.player = viewer == .video ? item.map { AVPlayer(url: $0.url) } : nil
        picture.image = nil
        if viewer == .picture, let url = item?.url { loadPicture(url) }
    }

    /// A screen-sized rendering made in the background, so a 100-megapixel RAW doesn't stall the window.
    private func loadPicture(_ url: URL) {
        pictureJob += 1
        let job = pictureJob
        let longest = 2 * max(bounds.width, 600)
        DispatchQueue.global(qos: .userInitiated).async {
            var image: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: longest] as CFDictionary) {
                // Animated GIFs keep their frames; everything else uses the downsized copy.
                image = url.pathExtension.lowercased() == "gif" ? NSImage(contentsOf: url) : NSImage(cgImage: cg, size: .zero)
            } else {
                image = NSImage(contentsOf: url)   // SVG, PDF-as-image and other things ImageIO can't read
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.pictureJob == job else { return }
                    self.picture.image = image
                }
            }
        }
    }

    /// Folder size is worked out in the background and added when it's ready.
    private func measure(_ url: URL) {
        sizeJob?.cancel()
        let job = Thread { [weak self] in
            let (bytes, files, folders) = Format.deepSize(url)
            if Thread.current.isCancelled { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.shown == url else { return }
                    self.addRow("Size", "\(Format.size(bytes)) · \(files) files, \(folders) folders")
                }
            }
        }
        sizeJob = job
        job.start()
    }

    private func fill(_ rows: [(String, String)], title: String?) {
        info.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let title {
            let t = NSTextField(wrappingLabelWithString: title)
            t.font = .boldSystemFont(ofSize: 13)
            info.addArrangedSubview(t)
        }
        rows.forEach { addRow($0.0, $0.1) }
    }

    private func addRow(_ key: String, _ value: String) {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 12)
        v.isSelectable = true
        let pair = NSStackView(views: [k, v])
        pair.orientation = .vertical
        pair.alignment = .leading
        pair.spacing = 0
        info.addArrangedSubview(pair)
    }
}

/// Properties (⌘I), like Explorer's: what it is, where it is, how big, when, and what's inside.
@MainActor
enum Properties {
    private static var windows: [NSWindow] = []

    static func show(_ item: FileItem) {
        let pane = PreviewPane(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(item.name) Properties"
        window.contentView = pane
        window.isReleasedWhenClosed = false
        window.center()
        pane.show([item])
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        window.makeKeyAndOrderFront(nil)
    }
}
