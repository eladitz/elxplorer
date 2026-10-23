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
        for v in [picture, preview, player, pdf, textScroll, model] as [NSView] {
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
        model.allowsCameraControl = true            // drag to rotate, pinch/scroll to zoom
        model.autoenablesDefaultLighting = true
        model.backgroundColor = .clear
        for v in [preview, picture, player, pdf, textScroll, model] as [NSView] {
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
            let ext = url.pathExtension.lowercased()
            var scene: SCNScene?
            if ["stl", "obj", "ply"].contains(ext) {
                let asset = MDLAsset(url: url)
                asset.loadTextures()
                scene = SCNScene(mdlAsset: asset)
            } else {
                scene = try? SCNScene(url: url, options: [.convertToYUp: true])
            }
            // Untextured meshes (most STL files) get a neutral matte material so their shape reads well.
            scene?.rootNode.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                if geometry.materials.isEmpty || ["stl", "ply"].contains(ext) {
                    let material = SCNMaterial()
                    material.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1)
                    material.lightingModel = .physicallyBased
                    material.roughness.contents = 0.6
                    geometry.materials = [material]
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.pictureJob == job else { return }
                    self.model.scene = scene
                    self.model.pointOfView = nil   // let SceneKit frame the whole model
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
