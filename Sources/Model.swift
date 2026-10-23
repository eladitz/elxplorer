// Files, settings and the operations that change the disk.

import AppKit
import UniformTypeIdentifiers

// MARK: - A file or folder in a listing

final class FileItem: NSObject {
    let url: URL
    let name: String
    let isFolder: Bool         // folders you navigate into (packages like .app count as files)
    let size: Int64?
    let modified: Date?
    let created: Date?
    let kind: String
    let typeID: String?
    let isHidden: Bool
    let tags: [String]

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .creationDateKey, .localizedTypeDescriptionKey, .typeIdentifierKey,
                                         .isHiddenKey, .tagNamesKey]

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: Set(Self.keys))
        name = url.lastPathComponent
        isFolder = v?.isDirectory == true && v?.isPackage != true
        size = isFolder ? nil : v?.fileSize.map(Int64.init)
        modified = v?.contentModificationDate
        created = v?.creationDate
        kind = v?.localizedTypeDescription ?? (isFolder ? "Folder" : "Document")
        typeID = v?.typeIdentifier
        isHidden = v?.isHidden == true || url.lastPathComponent.hasPrefix(".")
        tags = v?.tagNames ?? []
    }

    /// The name as shown: with or without its extension, per the setting.
    @MainActor var displayName: String {
        guard !Settings.shared.showExtensions, !isFolder, !url.pathExtension.isEmpty else { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Icons by file type are cached; folders and apps can have their own, so those ask for the real one.
    @MainActor var icon: NSImage {
        if isFolder || url.pathExtension == "app" || typeID == nil { return Icons.forFile(url) }
        return Icons.forType(typeID!)
    }
}

@MainActor
enum Icons {
    private static var byType: [String: NSImage] = [:]
    private static var byFile: [URL: NSImage] = [:]

    static func forType(_ id: String) -> NSImage {
        if let cached = byType[id] { return cached }
        let icon = UTType(id).map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data)
        byType[id] = icon
        return icon
    }

    static func forFile(_ url: URL) -> NSImage {
        if let cached = byFile[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if byFile.count > 2000 { byFile.removeAll() }
        byFile[url] = icon
        return icon
    }
}

// MARK: - Settings (one set for every folder and window)

@MainActor
final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("ElxplorerSettingsChanged")
    private let d = UserDefaults.standard

    private func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    private func set(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var showHidden: Bool { get { flag("showHidden", false) } set { set(newValue, "showHidden") } }
    var showExtensions: Bool { get { flag("showExtensions", true) } set { set(newValue, "showExtensions") } }
    var foldersFirst: Bool { get { flag("foldersFirst", true) } set { set(newValue, "foldersFirst") } }
    var showPreview: Bool { get { flag("showPreview", false) } set { set(newValue, "showPreview") } }
    var sortKey: String { get { d.string(forKey: "sortKey") ?? "name" } set { set(newValue, "sortKey") } }
    var ascending: Bool { get { flag("ascending", true) } set { set(newValue, "ascending") } }
    var groupBy: String { get { d.string(forKey: "groupBy") ?? "none" } set { set(newValue, "groupBy") } }
    var viewMode: String { get { d.string(forKey: "viewMode") ?? "details" } set { set(newValue, "viewMode") } }

    var pinned: [URL] {
        get { (d.stringArray(forKey: "pinned") ?? []).map { URL(fileURLWithPath: $0) } }
        set { set(newValue.map(\.path), "pinned") }
    }

    var savedSearches: [SavedSearch] {
        get { (d.data(forKey: "savedSearches")).flatMap { try? JSONDecoder().decode([SavedSearch].self, from: $0) } ?? [] }
        set { set((try? JSONEncoder().encode(newValue)) ?? Data(), "savedSearches") }
    }

    var lastSession: [URL] {
        get { (d.stringArray(forKey: "lastSession") ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: "lastSession") }   // no change notification: nothing redraws
    }
}

// MARK: - Sorting and grouping

enum Sorter {
    static func sort(_ items: [FileItem], key: String, ascending: Bool, foldersFirst: Bool) -> [FileItem] {
        items.sorted { a, b in
            if foldersFirst && a.isFolder != b.isFolder { return a.isFolder }
            let order: ComparisonResult
            switch key {
            case "modified": order = compare(a.modified, b.modified)
            case "created": order = compare(a.created, b.created)
            case "size": order = compare(a.size, b.size)
            case "kind": order = a.kind.localizedStandardCompare(b.kind)
            case "folder": order = a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
            default: order = .orderedSame
            }
            // Ties (and the name column) fall back to natural name order: "file 2" before "file 10".
            let final = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return ascending ? final == .orderedAscending : final == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?): return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (nil, _?): return .orderedAscending
        case (_?, nil): return .orderedDescending
        default: return .orderedSame
        }
    }

    /// Windows-style date buckets.
    static func dateGroup(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Earlier this week" }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now), cal.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return "Last week" }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return "Earlier this month" }
        if let lastMonth = cal.date(byAdding: .month, value: -1, to: now), cal.isDate(date, equalTo: lastMonth, toGranularity: .month) { return "Last month" }
        if cal.isDate(date, equalTo: now, toGranularity: .year) { return "Earlier this year" }
        return "A long time ago"
    }

    static let dateGroupOrder = ["Today", "Yesterday", "Earlier this week", "Last week", "Earlier this month",
                                 "Last month", "Earlier this year", "A long time ago", "Unknown"]
}

// MARK: - Loading a folder

enum Loader {
    static func load(_ folder: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileItem.keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map(FileItem.init)
    }
}

/// Calls back (debounced) whenever something inside a folder is added, removed or renamed.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(_ folder: URL, onChange: @escaping () -> Void) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}

// MARK: - Cut / copy / paste

@MainActor
enum Clipboard {
    private static let cutMarker = NSPasteboard.PasteboardType("com.itzkin.elxplorer.cut")
    /// Files cut and not yet pasted, shown dimmed like in Windows.
    private(set) static var cutURLs: Set<URL> = []

    static func copy(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])   // Finder can paste these too
        pb.addTypes([.string], owner: nil)
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        if cut {
            pb.addTypes([cutMarker], owner: nil)
            pb.setString("1", forType: cutMarker)
        }
        cutURLs = cut ? Set(urls) : []
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }

    static var contents: (urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, pb.string(forType: cutMarker) != nil)
    }

    static var canPaste: Bool { !contents.urls.isEmpty }

    static func pasted() {
        guard !cutURLs.isEmpty else { return }
        cutURLs = []
        NSPasteboard.general.clearContents()   // a cut can only be pasted once, as in Windows
    }
}

// MARK: - File operations

enum FileOps {
    /// "name.ext", or Windows' "name - Copy.ext", "name - Copy (2).ext" when taken.
    static func freeName(for name: String, in folder: URL, copySuffix: Bool) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 1... {
            let label = copySuffix ? (n == 1 ? " - Copy" : " - Copy (\(n))") : " (\(n + 1))"
            let candidate = folder.appendingPathComponent(base + label + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError()
    }

    /// Copies or moves files into a folder. Returns where they ended up.
    static func paste(_ urls: [URL], into folder: URL, move: Bool) throws -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        for url in urls {
            let sameFolder = url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
            if move && sameFolder { results.append(url); continue }   // cut and pasted back in place: nothing to do
            if folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") || folder.standardizedFileURL == url.standardizedFileURL {
                throw FileError("Can't put \(url.lastPathComponent) inside itself.")
            }
            let target = freeName(for: url.lastPathComponent, in: folder, copySuffix: !move)
            if move { try fm.moveItem(at: url, to: target) } else { try fm.copyItem(at: url, to: target) }
            results.append(target)
        }
        return results
    }

    static func newFolder(in folder: URL) throws -> URL {
        let url = freeName(for: "New Folder", in: folder, copySuffix: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func newFile(_ name: String, in folder: URL) throws -> URL {
        let url = freeName(for: name, in: folder, copySuffix: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw FileError("Couldn't create the file.") }
        return url
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { throw FileError("That name isn't allowed.") }
        let target = url.deletingLastPathComponent().appendingPathComponent(clean)
        if target == url { return url }
        if FileManager.default.fileExists(atPath: target.path) && target.path.lowercased() != url.path.lowercased() {
            throw FileError("There's already an item called “\(clean)” here.")
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw FileError("Nothing to compress.") }
        let folder = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        let out = freeName(for: name, in: folder, copySuffix: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = urls.count == 1 ? ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path] : []
        if urls.count > 1 {
            // ditto takes one source; zip several items from their folder instead.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = folder
            p.arguments = ["-r", "-y", "-q", out.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store"]
        }
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FileError("Compressing failed.") }
        return out
    }
}

struct FileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Saved searches

struct SavedSearch: Codable, Equatable {
    var name: String
    var root: String
    var query: String
    var contents: Bool
    var kind: String
    var date: String
    var size: String
}

// MARK: - Formatting

enum Format {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func size(_ n: Int64?) -> String {
        guard let n else { return "" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Total size of a folder (or file), walking everything inside. Call off the main thread.
    static func deepSize(_ url: URL) -> (bytes: Int64, files: Int, folders: Int) {
        var bytes: Int64 = 0, files = 0, folders = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), 1, 0)
        }
        while let f = walker.nextObject() as? URL {
            if Thread.current.isCancelled { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true { folders += 1 } else { files += 1; bytes += Int64(v.fileSize ?? 0) }
        }
        return (bytes, files, folders)
    }
}
