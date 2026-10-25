// The preview pane (Quick Look, which covers pictures, video, PDF, Office, 3D…) plus the file's details,
// and the Properties window.

import AppKit
import Quartz
import AVKit
import UniformTypeIdentifiers
import PDFKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import QuickLookThumbnailing

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
    private let pdf = PDFView()
    private let textScroll = NSTextView.scrollableTextView()
    private let model = SCNView()
    private let modelHint = NSTextField(labelWithString: "Drag to turn · Scroll to zoom · ⌥-drag to move")
    private let pile = PhotoPile()
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
        info.setClippingResistancePriority(.init(1), for: .horizontal)
        info.spacing = 4
        info.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        let infoScroll = NSScrollView()
        let holder = FlippedView()   // details read from the top down, not pinned to the bottom
        holder.addSubview(info)
        info.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([info.topAnchor.constraint(equalTo: holder.topAnchor), info.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                                     info.trailingAnchor.constraint(equalTo: holder.trailingAnchor), info.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
        holder.translatesAutoresizingMaskIntoConstraints = false
        infoScroll.documentView = holder
        infoScroll.hasVerticalScroller = true
        infoScroll.drawsBackground = false
        picture.imageScaling = .scaleProportionallyDown
        picture.animates = true   // GIFs play
        // An image view wants to be as big as its image; here it should just fit whatever room the pane has.
        for v in [picture, preview, player, pdf, textScroll, model, pile] as [NSView] {
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                v.setContentCompressionResistancePriority(.init(1), for: axis)
                v.setContentHuggingPriority(.init(1), for: axis)
            }
        }
        player.controlsStyle = .inline
        player.showsFullScreenToggleButton = true
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = .clear
        if let text = textScroll.documentView as? NSTextView {
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.backgroundColor = .textBackgroundColor
        }
        textScroll.hasVerticalScroller = true
        // Drag turns the model like a turntable (left/right spins, up/down tilts, never flips over),
        // with a little momentum; scroll or pinch zooms, ⌥-drag moves it.
        model.allowsCameraControl = true
        model.defaultCameraController.interactionMode = .orbitTurntable
        model.defaultCameraController.inertiaEnabled = true
        model.autoenablesDefaultLighting = true
        model.backgroundColor = .clear
        modelHint.font = .systemFont(ofSize: 11)
        modelHint.textColor = .secondaryLabelColor
        modelHint.alignment = .center
        modelHint.translatesAutoresizingMaskIntoConstraints = false
        model.addSubview(modelHint)
        NSLayoutConstraint.activate([modelHint.centerXAnchor.constraint(equalTo: model.centerXAnchor),
                                     modelHint.bottomAnchor.constraint(equalTo: model.bottomAnchor, constant: -6)])
        for v in [preview, picture, player, pdf, textScroll, model, pile] as [NSView] {
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
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: topAnchor), stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor), stage.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.6),
            infoScroll.topAnchor.constraint(equalTo: stage.bottomAnchor), infoScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoScroll.trailingAnchor.constraint(equalTo: trailingAnchor), infoScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            holder.widthAnchor.constraint(equalTo: infoScroll.contentView.widthAnchor),
            holder.topAnchor.constraint(equalTo: infoScroll.contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `items` in the order they were selected; with several, the most recent ends up on top of the pile.
    func show(_ items: [FileItem]) {
        guard items.count == 1, let item = items.first else {
            shown = nil
            display(nil)
            if items.count > 1 { showPile(items) } else { fill([], title: nil) }
            return
        }
        guard item.url != shown else { return }
        shown = item.url
        display(item)
        var rows: [(String, String)] = [("Type", item.kind),
                                         ("Location", Home.abbreviate(item.url.deletingLastPathComponent().path))]
        if let s = item.size { rows.append(("Size", Format.size(s))) }
        if let m = item.modified { rows.append(("Modified", Format.date.string(from: m))) }
        if let c = item.created { rows.append(("Created", Format.date.string(from: c))) }
        if !item.tags.isEmpty { rows.append(("Tags", item.tags.joined(separator: ", "))) }
        rows += Details.facts(item.url)
        fill(rows, title: item.name)
        if item.isFolder { measure(item.url) }
    }

    private func showPile(_ items: [FileItem]) {
        pile.isHidden = false
        pile.show(items.suffix(7).map(\.url), total: items.count)
        // "9 JPEG images, 2 QuickTime movies": what's in the selection, most common first.
        let kinds = Dictionary(grouping: items, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let summary = kinds.prefix(4).map { "\($0.1) \($0.0)" }.joined(separator: "\n") + (kinds.count > 4 ? "\n…" : "")
        let bytes = items.reduce(Int64(0)) { $0 + ($1.isFolder ? FolderSizes.shared.cached($1.url) ?? 0 : $1.size ?? 0) }
        fill([("Selected", "\(items.count) items"), ("Size", Format.size(bytes)), ("Contains", summary)], title: nil)
    }

    private enum Viewer { case quickLook, picture, video, pdf, text, model }

    private func viewer(for item: FileItem?) -> Viewer {
        guard let item, !item.isFolder else { return .quickLook }
        if FileItem.modelExtensions.contains(item.url.pathExtension.lowercased()) { return .model }
        guard let type = item.typeID.flatMap(UTType.init) else { return .quickLook }
        if type.conforms(to: .image) { return .picture }
        if type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .pdf) { return .pdf }
        if [.text, .sourceCode, .json, .xml, .propertyList].contains(where: { type.conforms(to: $0) }), !type.conforms(to: .rtf) { return .text }
        return .quickLook
    }

    private func display(_ item: FileItem?) {
        player.player?.pause()
        let viewer = viewer(for: item)
        preview.isHidden = viewer != .quickLook
        picture.isHidden = viewer != .picture
        player.isHidden = viewer != .video
        pdf.isHidden = viewer != .pdf
        textScroll.isHidden = viewer != .text
        model.isHidden = viewer != .model
        pile.isHidden = true
        preview.previewItem = viewer == .quickLook ? item?.url as NSURL? : nil
        player.player = viewer == .video ? item.map { AVPlayer(url: $0.url) } : nil
        pdf.document = viewer == .pdf ? item.flatMap { PDFDocument(url: $0.url) } : nil
        picture.image = nil
        model.scene = nil
        (textScroll.documentView as? NSTextView)?.string = ""
        guard let url = item?.url else { return }
        switch viewer {
        case .picture: loadPicture(url)
        case .text: loadText(url)
        case .model: loadModel(url)
        default: break
        }
    }

    /// The first 200 KB of a text or code file, in whatever encoding it's in.
    private func loadText(_ url: URL) {
        pictureJob += 1
        let job = pictureJob
        DispatchQueue.global(qos: .userInitiated).async {
            let limit = 200_000
            let handle = try? FileHandle(forReadingFrom: url)
            let data = (try? handle?.read(upToCount: limit)) ?? Data()
            try? handle?.close()
            var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let full = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if full > limit { text += "\n\n… (the preview shows the first 200 KB)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.pictureJob == job else { return }
                    (self.textScroll.documentView as? NSTextView)?.string = text
                    self.textScroll.documentView?.scroll(.zero)
                }
            }
        }
    }

    /// A 3D model you can turn and zoom. STL, OBJ and PLY go through Model I/O; USD, DAE, Alembic load directly.
    private func loadModel(_ url: URL) {
        pictureJob += 1
        let job = pictureJob
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = Model3D.scene(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.pictureJob == job else { return }
                    self.model.scene = scene
                    self.model.pointOfView = nil   // let SceneKit frame the whole model
                    if let scene { self.model.defaultCameraController.frameNodes(scene.rootNode.childNodes) }
                    if ProcessInfo.processInfo.environment["ELX_DEBUG"] != nil {
                        var meshes = 0, vertices = 0
                        scene?.rootNode.enumerateHierarchy { node, _ in
                            if let g = node.geometry { meshes += 1; vertices += g.sources(for: .vertex).first?.vectorCount ?? 0 }
                        }
                        print("3D:", url.lastPathComponent, "meshes", meshes, "vertices", vertices)
                    }
                }
            }
        }
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
            info.addArrangedSubview(yielding(t))
        }
        rows.forEach { addRow($0.0, $0.1) }
        needsLayout = true
    }

    /// Text in the pane wraps to the pane; it never asks for more room (which would stretch the window).
    private func yielding(_ label: NSTextField) -> NSTextField {
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.preferredMaxLayoutWidth = max(100, bounds.width - 24)
        return label
    }

    // The pane takes whatever size the window gives it, never the other way round.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        let width = max(100, bounds.width - 24)
        func update(_ view: NSView) {
            if let label = view as? NSTextField, label.preferredMaxLayoutWidth != width { label.preferredMaxLayoutWidth = width }
            view.subviews.forEach(update)
        }
        update(info)
    }

    private func addRow(_ key: String, _ value: String) {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        let v = yielding(NSTextField(wrappingLabelWithString: value))
        v.font = .systemFont(ofSize: 12)
        v.isSelectable = true
        let pair = NSStackView(views: [k, v])
        pair.orientation = .vertical
        pair.alignment = .leading
        pair.spacing = 0
        pair.setClippingResistancePriority(.init(1), for: .horizontal)
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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Several selected items as a pile of cards: the newest selection on top, straight and in full view;
/// earlier ones peek out beneath it, turned a little, like prints on a table.
@MainActor
final class PhotoPile: NSView {
    private var urls: [URL] = []          // bottom → top
    private var total = 0
    private var images: [URL: CGImage] = [:]
    private static let cache = NSCache<NSURL, CGImage>()
    private let badge = CATextLayer()
    private let angles: [CGFloat] = [0, -7, 5, -4, 8, -9, 3]       // by distance from the top card
    private let offsets: [CGPoint] = [.zero, CGPoint(x: -14, y: 8), CGPoint(x: 16, y: -6), CGPoint(x: -8, y: -12),
                                      CGPoint(x: 12, y: 12), CGPoint(x: -18, y: -2), CGPoint(x: 6, y: 16)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.fontSize = 13
        badge.font = NSFont.boldSystemFont(ofSize: 13)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.cornerRadius = 11
        badge.contentsScale = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ urls: [URL], total: Int) {
        self.urls = urls
        self.total = total
        images = images.filter { urls.contains($0.key) }
        for url in urls where images[url] == nil {
            if let cached = Self.cache.object(forKey: url as NSURL) { images[url] = cached } else { load(url) }
        }
        needsLayout = true
    }

    private func load(_ url: URL) {
        let size = 700
        DispatchQueue.global(qos: .userInitiated).async {
            var image: CGImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary)
            }
            let deliver: @Sendable (CGImage?) -> Void = { image in
                guard let image else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.cache.setObject(image, forKey: url as NSURL)
                        guard self.urls.contains(url) else { return }
                        self.images[url] = image
                        self.needsLayout = true
                    }
                }
            }
            if let image { deliver(image); return }
            // Not a picture: Quick Look's thumbnail (a PDF's first page, a video's frame, a document's icon).
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in deliver(rep?.cgImage) }
        }
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let box = CGSize(width: bounds.width * 0.72, height: bounds.height * 0.72)
        guard box.width > 20, box.height > 20 else { return }
        for (i, url) in urls.enumerated() {
            let depth = urls.count - 1 - i          // 0 for the top card
            let image = images[url]
            let aspect = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
            let scale = min(box.width / aspect, box.height)
            let size = CGSize(width: scale * aspect, height: scale)
            let card = CALayer()
            card.bounds = CGRect(origin: .zero, size: size)
            let offset = offsets[min(depth, offsets.count - 1)]
            card.position = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
            card.contents = image
            card.contentsGravity = .resizeAspectFill
            card.masksToBounds = false
            card.backgroundColor = NSColor.secondarySystemFill.cgColor
            card.borderColor = NSColor.white.cgColor
            card.borderWidth = 4
            card.cornerRadius = 3
            card.shadowColor = NSColor.black.cgColor
            card.shadowOpacity = 0.35
            card.shadowRadius = 6
            card.shadowOffset = CGSize(width: 0, height: -2)
            card.setAffineTransform(CGAffineTransform(rotationAngle: angles[min(depth, angles.count - 1)] * .pi / 180))
            layer?.addSublayer(card)
        }
        if total > 1 {
            badge.string = "\(total)"
            let width = max(22, CGFloat("\(total)".count) * 9 + 12)
            badge.frame = CGRect(x: bounds.maxX - width - 12, y: bounds.maxY - 34, width: width, height: 22)
            layer?.addSublayer(badge)
        }
    }
}
